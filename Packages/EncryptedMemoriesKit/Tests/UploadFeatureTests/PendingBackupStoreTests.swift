import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

/// Uses the store's real connection, including a refused rollback that leaves its transaction open.
enum PendingStoreTransactionFault: Equatable {
    case openTransaction, lastingFailure, failedRollback

    func install(on store: PendingBackupManifestStore, key: PendingSourceKey) throws -> SQLiteStoreConnection {
        let connection = try XCTUnwrap(
            Mirror(reflecting: store).children.first(where: { $0.label == "connection" })?.value
                as? SQLiteStoreConnection)
        switch self {
        case .openTransaction:
            connection.withLock {
                XCTAssertEqual(sqlite3_exec(connection.database, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
            }
        case .lastingFailure:
            connection.withLock {
                XCTAssertEqual(
                    sqlite3_set_authorizer(
                        connection.database,
                        { _, action, _, _, _, _ in
                            action == SQLITE_SELECT ? SQLITE_DENY : SQLITE_OK
                        }, nil), SQLITE_OK)
            }
            XCTAssertFalse(store.sourceStatesRead().complete)
        case .failedRollback:
            connection.withLock {
                XCTAssertEqual(
                    sqlite3_set_authorizer(
                        connection.database,
                        { _, action, name, _, _, _ in
                            if action == SQLITE_DELETE { return SQLITE_DENY }
                            if action == SQLITE_TRANSACTION, name.map({ String(cString: $0) }) == "ROLLBACK" {
                                return SQLITE_DENY
                            }
                            return SQLITE_OK
                        }, nil), SQLITE_OK)
            }
            XCTAssertFalse(store.removeEvidence([(key, UploadBackupRevision(rawValue: 1))]))
        }
        connection.withLock {
            sqlite3_set_authorizer(connection.database, nil, nil)
            XCTAssertEqual(sqlite3_get_autocommit(connection.database) == 0, self != .lastingFailure)
        }
        XCTAssertFalse(store.isOperational())
        return connection
    }

    static func remove(from connection: SQLiteStoreConnection) {
        connection.withLock {
            sqlite3_set_authorizer(connection.database, nil, nil)
            if sqlite3_get_autocommit(connection.database) == 0 {
                XCTAssertEqual(sqlite3_exec(connection.database, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
            }
        }
    }
}

final class PendingBackupStoreTests: XCTestCase {
    private var directory: URL!
    private var store: PendingBackupManifestStore!
    private let date = Date(timeIntervalSince1970: 1_750_000_000)
    private let key = PendingSourceKey(kind: .photoLibraryAsset, identifier: "asset-1")
    private let remote = PhotoUID(volumeID: "vol", nodeID: "link-1")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-backup-store-\(UUID().uuidString)", isDirectory: true)
        store = try XCTUnwrap(PendingBackupManifestStore(url: storeURL))
    }

    override func tearDownWithError() throws {
        store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL { directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName) }

    private func presentation(_ name: String = "IMG_0001.HEIC") -> PendingPresentationMetadata {
        PendingPresentationMetadata(captureTime: date, mediaType: "image/heic", displayName: name)
    }

    func testRestoreResultReadabilityDistinguishesUnknownStateFromPendingWork() {
        XCTAssertTrue(PendingBackupRestoreResult().isReadable)
        for outcome in [PendingBackupReturnOutcome.completed, .waiting(until: date), .remoteTrashed] {
            XCTAssertTrue(PendingBackupRestoreResult(outcomes: [key: outcome]).isReadable)
        }
        XCTAssertFalse(PendingBackupRestoreResult(discoveryComplete: false).isReadable)
        XCTAssertFalse(PendingBackupRestoreResult(outcomes: [key: .unreadable]).isReadable)
    }

    func testReverseHandoffLookupRejectsADecodedPrefix() throws {
        let healthy = PendingSourceKey(kind: .photoLibraryAsset, identifier: "asset-0")
        let healthyRemote = PhotoUID(volumeID: "vol", nodeID: "link-0")
        for (source, target) in [(healthy, healthyRemote), (key, remote)] {
            XCTAssertEqual(
                store.recordHandoff(
                    PendingHandoff(
                        key: source, revision: UploadBackupRevision(rawValue: 7), remote: target,
                        kind: .uploaded, createdAt: date)), .recorded)
        }
        try withRawPendingDatabase { db in
            XCTAssertEqual(
                sqlite3_exec(db, "UPDATE handoff SET kind='invalid' WHERE source_id='asset-1';", nil, nil, nil),
                SQLITE_OK)
        }
        let before = try pendingTables()

        let found = store.handoffs(forRemoteLinkIDs: [healthyRemote.nodeID, remote.nodeID])

        XCTAssertTrue(found.isEmpty, "an unreadable requested lookup cannot expose its healthy prefix")
        XCTAssertEqual(try pendingTables(), before, "discovery must not change durable state")
    }

    func testReverseHandoffLookupReturnsACompleteHealthyBatch() throws {
        let healthy = PendingSourceKey(kind: .photoLibraryAsset, identifier: "asset-0")
        let healthyRemote = PhotoUID(volumeID: "vol", nodeID: "link-0")
        for (source, target) in [(healthy, healthyRemote), (key, remote)] {
            XCTAssertEqual(
                store.recordHandoff(
                    PendingHandoff(
                        key: source, revision: UploadBackupRevision(rawValue: 7), remote: target,
                        kind: .uploaded, createdAt: date)), .recorded)
        }

        let found = store.handoffs(forRemoteLinkIDs: [healthyRemote.nodeID, remote.nodeID])

        XCTAssertEqual(found.map(\.key), [healthy, key])
        XCTAssertTrue(store.isOperational())
    }

    func testLaterTrashPruningKeepsAnUnreadableAcknowledgedHandoffAfterConfirmedTrash() throws {
        let earlier = PhotoUID(volumeID: "vol", nodeID: "earlier-upload")
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: earlier)], at: date))
        let revision = UploadBackupRevision(rawValue: 10)
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(
                    key: key, revision: revision, remote: remote, kind: .uploaded,
                    createdAt: date.addingTimeInterval(-8 * 24 * 60 * 60))), .excludedRemoteNeedsTrash)
        XCTAssertTrue(store.acknowledgeHandoffs([(key, revision)]))
        XCTAssertTrue(store.completeEffect(.queueSync, for: key, generation: 1, at: date))
        try withRawPendingDatabase {
            XCTAssertEqual(sqlite3_exec($0, "UPDATE handoff SET kind='invalid';", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertTrue(
            store.completeEffect(.remoteTrash, for: key, generation: 1, remoteLinkID: earlier.nodeID, at: date))
        let completed = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertTrue(completed.remoteTrashed, "A's confirmed trash must remain durable")
        XCTAssertFalse(completed.needsRemoteTrash)
        XCTAssertEqual(store.latestHandoffsRead(for: [key])[key], .unreadable)

        XCTAssertTrue(store.pruneAcknowledgedHandoffs(olderThan: date.addingTimeInterval(-7 * 24 * 60 * 60)))

        XCTAssertEqual(
            store.latestHandoffsRead(for: [key])[key], .unreadable,
            "pruning must preserve the unreadable B handoff needed after A's confirmed trash")
    }

    func testLaterTrashReportsItsSavedCompletionSeparatelyFromAnUnreadableHandoff() throws {
        let earlier = PhotoUID(volumeID: "vol", nodeID: "earlier-upload")
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: earlier)], at: date))
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(
                    key: key, revision: UploadBackupRevision(rawValue: 10), remote: remote,
                    kind: .uploaded, createdAt: date)), .excludedRemoteNeedsTrash)
        try withRawPendingDatabase {
            XCTAssertEqual(sqlite3_exec($0, "UPDATE handoff SET kind='invalid';", nil, nil, nil), SQLITE_OK)
        }

        XCTAssertEqual(
            store.completeEffectResult(
                .remoteTrash, for: key, generation: 1, remoteLinkID: earlier.nodeID, at: date), .laterHandoffUnreadable)

        let saved = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertTrue(saved.remoteTrashed)
        XCTAssertFalse(saved.needsRemoteTrash)
        XCTAssertEqual(saved.remote, earlier)
    }

    func testLaterTrashRecoveryKeepsANewerIncludedDecision() throws {
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: remote)], at: date))
        XCTAssertTrue(store.completeEffect(.remoteTrash, for: key, generation: 1, at: date))
        XCTAssertNotNil(store.include([key], at: date))
        let before = try XCTUnwrap(store.sourceState(for: key))

        XCTAssertEqual(store.resumeLaterTrash(for: key, at: date.addingTimeInterval(60)), .unchanged)

        XCTAssertEqual(store.sourceState(for: key), before)
        XCTAssertTrue(before.needsRemoteRestore)
    }

    func testLaterTrashRecoveryDoesNotOverwriteAnAlreadyOwedDifferentTarget() throws {
        let other = PhotoUID(volumeID: "vol", nodeID: "other-upload")
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: remote)], at: date))
        XCTAssertTrue(store.completeEffect(.remoteTrash, for: key, generation: 1, at: date))
        for (revision, target) in [(Int64(10), other), (Int64(11), remote)] {
            XCTAssertEqual(
                store.recordHandoff(
                    PendingHandoff(
                        key: key, revision: UploadBackupRevision(rawValue: revision), remote: target,
                        kind: .uploaded, createdAt: date.addingTimeInterval(Double(revision)))),
                .excludedRemoteNeedsTrash)
        }
        XCTAssertTrue(store.deferEffects(for: key, at: date))
        let before = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertTrue(before.needsRemoteTrash)
        XCTAssertTrue(before.remoteTrashed)
        XCTAssertEqual(before.remote, other)

        XCTAssertEqual(store.resumeLaterTrash(for: key, at: date.addingTimeInterval(60)), .unchanged)

        XCTAssertEqual(
            store.sourceState(for: key), before, "recovery must preserve the target, attempts and future date")
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [before]), [key])
        let inFlight = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertEqual(store.resumeLaterTrash(for: key, at: date.addingTimeInterval(60)), .unchanged)
        XCTAssertEqual(store.sourceState(for: key), inFlight, "an in-flight request must remain owned")
    }

    func testLaterTrashRecoveryWithNoOrTheSameHandoffDoesNotCreateWork() throws {
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: remote)], at: date))
        XCTAssertTrue(store.completeEffect(.remoteTrash, for: key, generation: 1, at: date))
        let before = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertEqual(store.resumeLaterTrash(for: key, at: date.addingTimeInterval(60)), .unchanged)
        XCTAssertEqual(store.sourceState(for: key), before)
        // A handoff for this same photo can remain from before the confirmed trash.
        try withRawPendingDatabase {
            XCTAssertEqual(
                sqlite3_exec(
                    $0,
                    """
                    INSERT INTO handoff VALUES('photoLibraryAsset', 'asset-1', 10, 'vol', 'link-1', 'uploaded', 0, 1);
                    """, nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(store.resumeLaterTrash(for: key, at: date.addingTimeInterval(60)), .unchanged)
        XCTAssertEqual(store.sourceState(for: key), before)
    }

    func testRecordHandoffRejectsUnreadableSourceState() throws {
        try withUnreadableSourceState { _ in
            let handoff = PendingHandoff(
                key: key, revision: UploadBackupRevision(rawValue: 7), remote: remote,
                kind: .uploaded, createdAt: date)
            XCTAssertEqual(store.recordHandoff(handoff), .failed)
        }
    }

    func testIncludeRejectsUnreadableSourceStateAndRollsBackBatch() throws {
        try withUnreadableSourceState { _ in
            let earlier = PendingSourceKey(kind: .photoLibraryAsset, identifier: "asset-0")
            XCTAssertNil(store.include([earlier, key], at: date.addingTimeInterval(10)))
        }
    }

    func testCompleteEffectRejectsUnreadableSourceState() throws {
        try withUnreadableSourceState { state in
            XCTAssertFalse(
                store.completeEffect(.remoteTrash, for: key, generation: state.generation, at: date))
        }
    }

    func testDeferEffectsRejectsUnreadableSourceState() throws {
        try withUnreadableSourceState { _ in
            XCTAssertFalse(store.deferEffects(for: key, at: date))
        }
    }

    func testExcludeRejectsUnreadablePreviousSourceState() throws {
        try withUnreadableSourceState { _ in
            XCTAssertNil(
                store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: nil)], at: date))
        }
    }

    func testExcludeRejectsUnknownRemoteOperationAfterInterruptedRestore() throws {
        try assertRejectsSourceStateEnum("unknown")
    }

    func testExcludeRejectsEmbeddedNULRemoteOperationAfterInterruptedRestore() throws {
        try assertRejectsSourceStateEnum("remoteTrash\u{0}unknown")
    }

    func testExcludeRejectsEmbeddedNULDesiredAfterInterruptedRestore() throws {
        try assertRejectsSourceStateEnum("included\u{0}unknown", column: "desired", index: 2, repaired: "included")
    }

    func testReadsRejectEmbeddedNULSourceKindAfterInterruptedRestore() throws {
        try assertRejectsSourceStateEnum(
            "photoLibraryAsset\u{0}unknown", column: "source_kind", index: 0, repaired: "photoLibraryAsset")
    }

    private func assertRejectsSourceStateEnum(
        _ marker: String, column: String = "remote_op", index: Int = 20, repaired: String = "remoteRestore"
    ) throws {
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: remote)], at: date))
        XCTAssertTrue(store.completeEffect(.remoteTrash, for: key, generation: 1, at: date))
        let included = try XCTUnwrap(store.include([key], at: date))
        XCTAssertEqual(store.beginRemoteOperation(.remoteRestore, for: included), [key])
        let restoring = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertTrue(restoring.remoteTrashed)
        XCTAssertTrue(restoring.needsRemoteRestore)
        XCTAssertEqual(restoring.remoteOperation, .remoteRestore)

        // The restore may have succeeded remotely, but the app ends before recording its completion.
        store.close()
        store = try XCTUnwrap(PendingBackupManifestStore(url: storeURL))
        try withRawPendingDatabase { db in
            var stmt: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(db, "UPDATE source_state SET \(column)=?;", -1, &stmt, nil), SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            marker.withCString {
                XCTAssertEqual(
                    sqlite3_bind_text(
                        stmt, 1, $0, Int32(marker.utf8.count), SQLiteStoreSchemaGate.transientDestructor), SQLITE_OK)
            }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        }
        let before = try pendingTables()
        XCTAssertEqual(try XCTUnwrap(before["source_state"]?.first)[index], Data(marker.utf8))
        if column == "source_kind" {
            // A typed-key lookup cannot select the corrupted key; all-row readers must reject its decoded prefix.
            XCTAssertTrue(store.sourceStates().isEmpty)
            XCTAssertTrue(store.dueSourceStates(by: date.addingTimeInterval(10)).isEmpty)
        } else {
            XCTAssertNil(
                store.exclude(
                    [PendingExclusionRequest(key: key, presentation: nil, remote: nil)], at: date.addingTimeInterval(10)
                ))
        }
        // A row that does not decode stops nothing else; it stays unreadable and unchanged (#982).
        XCTAssertTrue(store.isOperational(), "an unknown non-null enum stops only its own row")
        XCTAssertEqual(try pendingTables(), before, "rejection must preserve the interrupted restore row")
        store.close()
        store = try XCTUnwrap(PendingBackupManifestStore(url: storeURL))
        XCTAssertEqual(try pendingTables(), before, "the unchanged row must survive reopen")

        // Repair only the enum, then prove the retained restore still makes the next exclusion owe trash.
        try withRawPendingDatabase {
            XCTAssertEqual(
                sqlite3_exec($0, "UPDATE source_state SET \(column)='\(repaired)';", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(store.sourceState(for: key), restoring)
        let excluded = try XCTUnwrap(
            try XCTUnwrap(
                store.exclude(
                    [PendingExclusionRequest(key: key, presentation: nil, remote: nil)],
                    at: date.addingTimeInterval(10))
            ).first)
        XCTAssertEqual(excluded.generation, restoring.generation + 1)
        XCTAssertEqual(excluded.remote, remote)
        XCTAssertEqual(excluded.presentation, restoring.presentation)
        XCTAssertTrue(excluded.needsRemoteTrash, "the interrupted restore may have made the remote photo active")
        XCTAssertTrue(store.isOperational())
    }

    func testExcludeAcceptsSQLNullRemoteOperation() throws {
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: remote)], at: date))
        XCTAssertTrue(store.completeEffect(.remoteTrash, for: key, generation: 1, at: date))
        XCTAssertNil(store.sourceState(for: key)?.remoteOperation)
        let excluded = try XCTUnwrap(
            try XCTUnwrap(
                store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: nil)], at: date)
            ).first)
        XCTAssertEqual(excluded.generation, 2)
        XCTAssertTrue(excluded.remoteTrashed)
        XCTAssertFalse(excluded.needsRemoteTrash, "SQL NULL means no interrupted restore")
        XCTAssertTrue(store.isOperational())
    }

    func testAbsentSourceStateKeepsEachWriterResult() throws {
        XCTAssertEqual(store.include([key], at: date), [])
        XCTAssertTrue(store.completeEffect(.remoteTrash, for: key, generation: 1, at: date))
        XCTAssertTrue(store.deferEffects(for: key, at: date))
        XCTAssertTrue(store.sourceStates().isEmpty)
        let handoff = PendingHandoff(
            key: key, revision: UploadBackupRevision(rawValue: 7), remote: remote,
            kind: .uploaded, createdAt: date)
        XCTAssertEqual(store.recordHandoff(handoff), .recorded)
        XCTAssertEqual(store.unacknowledgedHandoffs(), [handoff])
        let states = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: nil)], at: date))
        XCTAssertEqual(states.first?.generation, 1)
        XCTAssertNil(states.first?.remote)
        XCTAssertFalse(states.first?.needsRemoteTrash ?? true)
        XCTAssertTrue(store.isOperational())
    }

    func testSuccessfulSourceReadDoesNotInheritAnUnrelatedStickyFailure() throws {
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: remote)], at: date))
        XCTAssertTrue(store.setFavoriteIntent(key, favorite: true, at: date))
        // A denied read is no transient failure, so it stays recorded (#982); a row that does not decode records none.
        try withOneDeniedSourceSelect { _ = store.actions() }
        XCTAssertFalse(store.isOperational())
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(
                    key: key, revision: UploadBackupRevision(rawValue: 7), remote: remote,
                    kind: .uploaded, createdAt: date)), .excludedRemoteNeedsTrash)
        let included = try XCTUnwrap(try XCTUnwrap(store.include([key], at: date)).first)
        XCTAssertFalse(store.deferEffects(for: key, at: date), "a lasting failure refuses a standalone retry write")
        XCTAssertTrue(store.completeEffect(.queueSync, for: key, generation: included.generation, at: date))
        XCTAssertNotNil(store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: nil)], at: date))
        XCTAssertFalse(store.isOperational(), "successful reads must not clear sticky health")
    }

    func testClosedSourceReadIsNotAbsenceForWriters() {
        store.close()
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(
                    key: key, revision: UploadBackupRevision(rawValue: 7), remote: remote,
                    kind: .uploaded, createdAt: date)), .failed)
        XCTAssertNil(store.include([key], at: date))
        XCTAssertNil(store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: nil)], at: date))
        XCTAssertFalse(store.completeEffect(.queueSync, for: key, generation: 1, at: date))
        XCTAssertFalse(store.deferEffects(for: key, at: date))
    }

    /// Exercise a decode error and a one-shot prepare error on the real connection, without a production hook.
    private func withUnreadableSourceState(_ body: (PendingSourceState) throws -> Void) throws {
        for corruptRow in [false, true] {
            let earlier = PendingSourceKey(kind: .photoLibraryAsset, identifier: "asset-0")
            let requests = [earlier, key].map {
                PendingExclusionRequest(key: $0, presentation: presentation(), remote: remote)
            }
            XCTAssertNotNil(store.exclude(requests, at: date))
            // A repeated exclusion must retain its generation and remote trash, even if the next read fails.
            XCTAssertNotNil(store.exclude(requests, at: date))
            let state = try XCTUnwrap(store.sourceState(for: key))
            if corruptRow {
                try withRawPendingDatabase {
                    XCTAssertEqual(
                        sqlite3_exec(
                            $0, "UPDATE source_state SET desired='invalid' WHERE source_id='asset-1';",
                            nil, nil, nil), SQLITE_OK)
                }
            }
            let before = try pendingTables()
            if corruptRow {
                try body(state)
            } else {
                try withOneDeniedSourceSelect { try body(state) }
            }
            // A failed call that is not transient stays recorded; a row that does not decode stops nothing (#982).
            XCTAssertEqual(store.isOperational(), corruptRow, "a failed read records failed health, a bad row does not")
            XCTAssertEqual(try pendingTables(), before, "a failed writer must not change any persisted row")
            if corruptRow {
                try withRawPendingDatabase {
                    XCTAssertEqual(
                        sqlite3_exec(
                            $0, "UPDATE source_state SET desired='excluded' WHERE source_id='asset-1';",
                            nil, nil, nil), SQLITE_OK)
                }
            }
            store.close()
            store = try XCTUnwrap(PendingBackupManifestStore(url: storeURL))
            XCTAssertEqual(store.sourceState(for: key), state, "the owed effect survives failure and reopen")
            XCTAssertTrue(store.isOperational())
        }
    }

    private final class SelectDenial {
        var denied = false
    }

    private func pendingConnection() throws -> SQLiteStoreConnection {
        try XCTUnwrap(
            Mirror(reflecting: store!).children.first(where: { $0.label == "connection" })?.value
                as? SQLiteStoreConnection)
    }

    private func withOneDeniedSourceSelect(_ body: () throws -> Void) throws {
        let connection = try pendingConnection()
        let denial = SelectDenial()
        connection.withLock {
            XCTAssertEqual(
                sqlite3_set_authorizer(
                    connection.database,
                    { context, action, _, _, _, _ in
                        guard let context, action == SQLITE_SELECT else { return SQLITE_OK }
                        let denial = Unmanaged<SelectDenial>.fromOpaque(context).takeUnretainedValue()
                        guard !denial.denied else { return SQLITE_OK }
                        denial.denied = true
                        return SQLITE_DENY
                    }, Unmanaged.passUnretained(denial).toOpaque()), SQLITE_OK)
        }
        defer { connection.withLock { sqlite3_set_authorizer(connection.database, nil, nil) } }
        try body()
        XCTAssertTrue(denial.denied, "the writer must reach the failed prepare")
    }

    private func withRawPendingDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        return try body(db)
    }

    /// Binds `marker` as text with an explicit byte length, so an embedded NUL reaches the column verbatim.
    private func bindRawText(_ marker: String, _ update: String) throws {
        try withRawPendingDatabase { db in
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, update, -1, &stmt, nil), SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            marker.withCString {
                XCTAssertEqual(
                    sqlite3_bind_text(
                        stmt, 1, $0, Int32(marker.utf8.count), SQLiteStoreSchemaGate.transientDestructor),
                    SQLITE_OK)
            }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        }
    }

    /// Reads one column's raw bytes from the row of `source`, so a test can prove what the column really holds.
    private func storedBytes(
        of column: String, in table: String, kind: UploadSourceIdentity.Kind, identifier: String
    ) throws -> Data {
        try withRawPendingDatabase { db in
            var stmt: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db, "SELECT \(column) FROM \(table) WHERE source_kind=? AND source_id=?;", -1, &stmt, nil),
                SQLITE_OK)
            let prepared = try XCTUnwrap(stmt)
            defer { sqlite3_finalize(prepared) }
            kind.rawValue.utf8CString.withUnsafeBufferPointer { kindBytes in
                identifier.utf8CString.withUnsafeBufferPointer { identifierBytes in
                    XCTAssertEqual(
                        sqlite3_bind_text(
                            prepared, 1, kindBytes.baseAddress, Int32(kindBytes.count - 1),
                            SQLiteStoreSchemaGate.transientDestructor), SQLITE_OK)
                    XCTAssertEqual(
                        sqlite3_bind_text(
                            prepared, 2, identifierBytes.baseAddress, Int32(identifierBytes.count - 1),
                            SQLiteStoreSchemaGate.transientDestructor), SQLITE_OK)
                }
            }
            XCTAssertEqual(sqlite3_step(prepared), SQLITE_ROW)
            let bytes = sqlite3_column_blob(prepared, 0)
            let count = Int(sqlite3_column_bytes(prepared, 0))
            guard count > 0, let bytes else { return Data() }
            return Data(bytes: bytes, count: count)
        }
    }

    private func pendingTables() throws -> [String: [[Data?]]] {
        try withRawPendingDatabase { db in
            var result: [String: [[Data?]]] = [:]
            for table in [
                "pending_info", "source_state", "upload_evidence", "handoff", "pending_action", "saved_from_app",
            ] {
                var stmt: OpaquePointer?
                XCTAssertEqual(
                    sqlite3_prepare_v2(db, "SELECT * FROM \(table) ORDER BY rowid;", -1, &stmt, nil), SQLITE_OK)
                defer { sqlite3_finalize(stmt) }
                var rows: [[Data?]] = []
                var step = sqlite3_step(stmt)
                while step == SQLITE_ROW {
                    rows.append(
                        try (0..<sqlite3_column_count(stmt)).map { column -> Data? in
                            guard sqlite3_column_type(stmt, column) != SQLITE_NULL else { return nil }
                            let bytes = sqlite3_column_blob(stmt, column)
                            let count = Int(sqlite3_column_bytes(stmt, column))
                            guard count > 0 else { return Data() }
                            return Data(bytes: try XCTUnwrap(bytes), count: count)
                        })
                    step = sqlite3_step(stmt)
                }
                XCTAssertEqual(step, SQLITE_DONE)
                result[table] = rows
            }
            return result
        }
    }

    // MARK: - Desired state

    func testDeleteThenRestoreRunsTheQueueSyncOfTheNewestGeneration() throws {
        let excluded = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: nil)], at: date)
        ).first
        XCTAssertEqual(excluded?.desired, .excluded)
        XCTAssertEqual(excluded?.generation, 1)
        XCTAssertEqual(excluded?.needsQueueSync, true)
        XCTAssertEqual(excluded?.needsRemoteTrash, false)
        XCTAssertEqual(excluded?.listedInTrash, true)
        XCTAssertEqual(store.exclusions(kind: .photoLibraryAsset, among: ["asset-1", "other"]), ["asset-1": .excluded])

        let included = try XCTUnwrap(store.include([key], at: date)).first
        XCTAssertEqual(included?.desired, .included)
        XCTAssertEqual(included?.generation, 2)

        // A late completion of the delete's queue sync must not clear the restore's request.
        XCTAssertTrue(store.completeEffect(.queueSync, for: key, generation: 1, at: date))
        XCTAssertEqual(store.sourceState(for: key)?.needsQueueSync, true)

        XCTAssertTrue(store.completeEffect(.queueSync, for: key, generation: 2, at: date))
        XCTAssertNil(store.sourceState(for: key), "an included source without due effects leaves the store")
        XCTAssertEqual(store.exclusions(kind: .photoLibraryAsset, among: ["asset-1"]), [:])
    }

    func testDeleteOfAnUploadedPhotoTrashesItAndShowsOnlyTheProtonTrashEntry() throws {
        let state = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: remote)], at: date)
        ).first
        XCTAssertEqual(state?.needsRemoteTrash, true)
        XCTAssertEqual(state?.listedInTrash, false, "the Proton trash represents a photo that was uploaded")
        XCTAssertEqual(state?.remote, remote)

        XCTAssertTrue(store.completeEffect(.remoteTrash, for: key, generation: 1, at: date))
        let trashed = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertTrue(trashed.remoteTrashed)
        XCTAssertFalse(trashed.needsRemoteTrash)
        XCTAssertEqual(trashed.desired, .excluded, "a later edit of the photo must still not upload")

        let restored = try XCTUnwrap(store.include([key], at: date)).first
        XCTAssertEqual(restored?.needsRemoteRestore, true)
        XCTAssertTrue(store.completeEffect(.remoteRestore, for: key, generation: 2, at: date))
        XCTAssertTrue(store.completeEffect(.queueSync, for: key, generation: 2, at: date))
        XCTAssertNil(store.sourceState(for: key))
    }

    func testTrashThatFinishesAfterARestoreSchedulesTheRemoteRestore() throws {
        _ = store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: remote)], at: date)
        _ = store.include([key], at: date)
        XCTAssertEqual(store.sourceState(for: key)?.needsRemoteRestore, false, "nothing was trashed yet")

        // The trash request was already in flight and completes now.
        XCTAssertTrue(store.completeEffect(.remoteTrash, for: key, generation: 1, at: date))
        let state = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertEqual(state.desired, .included)
        XCTAssertTrue(state.needsRemoteRestore, "a stale trash must never undo the newer restore")
    }

    func testRestoreThatFinishesAfterANewDeleteSchedulesTheTrashAgain() throws {
        _ = store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: remote)], at: date)
        _ = store.completeEffect(.remoteTrash, for: key, generation: 1, at: date)
        _ = store.include([key], at: date)
        let deletedAgain = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: nil)], at: date)
        ).first
        XCTAssertEqual(deletedAgain?.needsRemoteTrash, false, "the photo is still in the Proton trash")
        XCTAssertEqual(deletedAgain?.generation, 3)
        XCTAssertNotNil(deletedAgain?.presentation, "a delete without metadata keeps the stored presentation")

        // The restore request of generation 2 was in flight and completes now.
        XCTAssertTrue(store.completeEffect(.remoteRestore, for: key, generation: 2, at: date))
        let state = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertEqual(state.desired, .excluded)
        XCTAssertTrue(state.needsRemoteTrash, "a stale restore must never undo the newer delete")
    }

    func testCommitThatRacesADeleteSchedulesTheTrashInTheSameTransaction() throws {
        _ = store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: nil)], at: date)
        let handoff = PendingHandoff(
            key: key,
            revision: UploadBackupRevision(rawValue: 5),
            remote: remote,
            kind: .uploaded,
            createdAt: date
        )

        XCTAssertEqual(store.recordHandoff(handoff), .excludedRemoteNeedsTrash)
        let state = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertTrue(state.needsRemoteTrash)
        XCTAssertEqual(state.remote, remote)
        XCTAssertEqual(store.unacknowledgedHandoffs(), [handoff])
    }

    func testDeleteFindsACommitWhoseEventHasNotArrivedYet() throws {
        let revision = UploadBackupRevision(rawValue: 3)
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(key: key, revision: revision, remote: remote, kind: .uploaded, createdAt: date)),
            .recorded)

        let state = try XCTUnwrap(
            store.exclude(
                [PendingExclusionRequest(key: key, presentation: presentation(), remote: nil, revision: revision)],
                at: date)
        ).first
        XCTAssertEqual(state?.remote, remote)
        XCTAssertEqual(state?.needsRemoteTrash, true, "the committed photo must still go to the trash")
    }

    // Mutation: prefer the durable handoff over `request.remote` in `exclude`; the earlier upload never goes to the
    // trash.
    func testDeleteOfAnEditTrashesTheHiddenEarlierUploadAndThenItsOwnCommit() throws {
        let edit = UploadBackupRevision(rawValue: 4)
        let earlier = PhotoUID(volumeID: "vol", nodeID: "link-earlier")
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(key: key, revision: edit, remote: remote, kind: .uploaded, createdAt: date)),
            .recorded)

        // The coordinator sends the earlier upload because the event of the edit's commit has not arrived yet.
        let state = try XCTUnwrap(
            store.exclude(
                [PendingExclusionRequest(key: key, presentation: presentation(), remote: earlier, revision: edit)],
                at: date)
        ).first
        XCTAssertEqual(state?.remote, earlier, "the photo that the tile shows goes to the trash first")
        XCTAssertEqual(state?.needsRemoteTrash, true)

        XCTAssertTrue(
            store.completeEffect(.remoteTrash, for: key, generation: 1, remoteLinkID: earlier.nodeID, at: date))
        let next = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertEqual(next.remote, remote, "the committed edit follows the earlier upload to the trash")
        XCTAssertTrue(next.needsRemoteTrash)
    }

    /// The delete of an edit could not read its handoff and named no photo. A later proof sends the earlier upload to
    /// the trash only for that same delete while it still names no photo.
    func testTrashOfAnEarlierUploadNeedsTheSameDeleteWithoutAPhoto() throws {
        let earlier = PhotoUID(volumeID: "vol", nodeID: "link-earlier")
        let other = PhotoUID(volumeID: "vol", nodeID: "link-other")
        let deleted = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: nil)], at: date)?
                .first)
        XCTAssertNil(deleted.remote)

        let stale = try XCTUnwrap(
            store.trashEarlierUpload(earlier, of: key, generation: deleted.generation + 1, at: date))
        XCTAssertNil(stale.remote, "another delete or a restore changed the generation")
        XCTAssertFalse(stale.needsRemoteTrash)

        let trashed = try XCTUnwrap(
            store.trashEarlierUpload(earlier, of: key, generation: deleted.generation, at: date))
        XCTAssertEqual(trashed.remote, earlier)
        XCTAssertTrue(trashed.needsRemoteTrash)
        XCTAssertFalse(trashed.listedInTrash, "the Proton trash represents the photo")

        let again = try XCTUnwrap(store.trashEarlierUpload(other, of: key, generation: deleted.generation, at: date))
        XCTAssertEqual(again.remote, earlier, "a delete that names a photo keeps it")

        let included = try XCTUnwrap(store.include([key], at: date)?.first)
        let restored = try XCTUnwrap(
            store.trashEarlierUpload(other, of: key, generation: included.generation, at: date))
        XCTAssertEqual(restored.desired, .included, "a restored photo never goes to the trash")
        XCTAssertNotEqual(restored.remote, other)

        let withoutPhoto = PendingSourceKey(kind: .photoLibraryAsset, identifier: "restored-without-photo")
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: withoutPhoto, presentation: nil, remote: nil)], at: date))
        let includedWithoutPhoto = try XCTUnwrap(store.include([withoutPhoto], at: date)?.first)
        let unchanged = try XCTUnwrap(
            store.trashEarlierUpload(other, of: withoutPhoto, generation: includedWithoutPhoto.generation, at: date))
        XCTAssertNil(unchanged.remote, "the same generation cannot authorize trash after a restore")
        XCTAssertFalse(unchanged.needsRemoteTrash)
    }

    func testEarlierUploadWaitsForAnInFlightOperationEvenWithoutARemoteTarget() throws {
        let first = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: remote)], at: date)?
                .first)
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [first]), [key])
        let deleted = try XCTUnwrap(
            store.exclude(
                [PendingExclusionRequest(key: key, presentation: presentation(), remote: nil, remoteUnknown: true)],
                at: date)?.first)
        XCTAssertNil(deleted.remote)
        XCTAssertFalse(deleted.needsRemoteTrash)
        XCTAssertEqual(deleted.remoteOperation, .remoteTrash)
        let earlier = PhotoUID(volumeID: "vol", nodeID: "earlier-after-operation")

        let unchanged = try XCTUnwrap(
            store.trashEarlierUpload(earlier, of: key, generation: deleted.generation, at: date))

        XCTAssertNil(unchanged.remote, "an in-flight operation alone blocks a new target")
        XCTAssertFalse(unchanged.needsRemoteTrash)
        XCTAssertEqual(unchanged.remoteOperation, .remoteTrash)
    }

    // Mutation: drop the early return for a pending trash in `recordHandoff`; the earlier upload is never trashed.
    // Mutation: drop the `needs_remote_trash` condition in `pruneAcknowledgedHandoffs`; the edit is never trashed.
    func testEditThatCommitsBeforeTheEarlierTrashIsSentKeepsBothTrashesDue() throws {
        let earlier = PhotoUID(volumeID: "vol", nodeID: "link-earlier")
        let edit = UploadBackupRevision(rawValue: 4)
        _ = store.exclude(
            [PendingExclusionRequest(key: key, presentation: presentation(), remote: earlier, revision: edit)],
            at: date)
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(key: key, revision: edit, remote: remote, kind: .uploaded, createdAt: date)),
            .excludedRemoteNeedsTrash)
        let waiting = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertEqual(waiting.remote, earlier, "the trash of the earlier upload stays owed")
        XCTAssertTrue(waiting.needsRemoteTrash)
        XCTAssertTrue(store.acknowledgeHandoffs([(key, edit)]))
        XCTAssertTrue(store.pruneAcknowledgedHandoffs(olderThan: date.addingTimeInterval(1)))

        XCTAssertTrue(
            store.completeEffect(.remoteTrash, for: key, generation: 1, remoteLinkID: earlier.nodeID, at: date))
        let next = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertEqual(next.remote, remote)
        XCTAssertTrue(next.needsRemoteTrash)
        XCTAssertFalse(next.remoteTrashed)

        XCTAssertTrue(
            store.completeEffect(.remoteTrash, for: key, generation: 1, remoteLinkID: remote.nodeID, at: date))
        let done = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertTrue(done.remoteTrashed)
        XCTAssertFalse(done.needsRemoteTrash)
    }

    func testEditThatCommitsWhileItsEarlierUploadMovesToTheTrashStillGoesToTheTrash() throws {
        let earlier = PhotoUID(volumeID: "vol", nodeID: "link-earlier")
        let excluded = try XCTUnwrap(
            store.exclude(
                [
                    PendingExclusionRequest(
                        key: key, presentation: presentation(), remote: earlier,
                        revision: UploadBackupRevision(rawValue: 4))
                ],
                at: date)
        )
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: excluded), [key])
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(
                    key: key, revision: UploadBackupRevision(rawValue: 4), remote: remote, kind: .uploaded,
                    createdAt: date)),
            .excludedRemoteNeedsTrash)

        // The trash of the earlier upload confirms after the edit committed.
        XCTAssertTrue(
            store.completeEffect(.remoteTrash, for: key, generation: 1, remoteLinkID: earlier.nodeID, at: date))
        let state = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertEqual(state.remote, remote)
        XCTAssertTrue(state.needsRemoteTrash, "the committed edit must still go to the trash")
        XCTAssertNil(state.remoteOperation)
        XCTAssertEqual(store.dueSourceStates(by: date).map(\.key), [key])
    }

    /// The trash of the earlier upload confirms while the handoff of the committed edit cannot be read. The trash stays
    /// due with the backoff; once the handoff reads again, the next confirmation moves on to the edit exactly once.
    func testAnUnreadableHandoffKeepsTheTrashOfTheEarlierUploadDue() throws {
        let earlier = PhotoUID(volumeID: "vol", nodeID: "link-earlier")
        let excluded = try XCTUnwrap(
            store.exclude(
                [
                    PendingExclusionRequest(
                        key: key, presentation: presentation(), remote: earlier,
                        revision: UploadBackupRevision(rawValue: 4))
                ],
                at: date)
        )
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: excluded), [key])
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(
                    key: key, revision: UploadBackupRevision(rawValue: 4), remote: remote, kind: .uploaded,
                    createdAt: date)),
            .excludedRemoteNeedsTrash)
        try withRawPendingDatabase {
            XCTAssertEqual(sqlite3_exec($0, "UPDATE handoff SET kind='invalid';", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(store.latestHandoffsRead(for: [key])[key], .unreadable)

        XCTAssertTrue(
            store.completeEffect(.remoteTrash, for: key, generation: 1, remoteLinkID: earlier.nodeID, at: date))

        let waiting = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertEqual(waiting.remote, earlier, "no photo is chosen on an unreadable handoff")
        XCTAssertTrue(waiting.needsRemoteTrash, "the trash stays due")
        XCTAssertFalse(waiting.remoteTrashed, "nothing is completed on an unreadable handoff")
        XCTAssertEqual(waiting.remoteOperation, .remoteTrash, "the sent trash may have happened")
        XCTAssertEqual(waiting.attempts, 1)
        XCTAssertTrue(store.dueSourceStates(by: date).isEmpty, "the retry waits for the backoff")
        XCTAssertEqual(store.nextEffectDate(), date.addingTimeInterval(60))

        try withRawPendingDatabase {
            XCTAssertEqual(sqlite3_exec($0, "UPDATE handoff SET kind='uploaded';", nil, nil, nil), SQLITE_OK)
        }
        let retry = date.addingTimeInterval(60)
        let due = store.dueSourceStates(by: retry)
        XCTAssertEqual(due.map(\.key), [key])
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: due), [key])
        XCTAssertTrue(
            store.completeEffect(.remoteTrash, for: key, generation: 1, remoteLinkID: earlier.nodeID, at: retry))
        let movedOn = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertEqual(movedOn.remote, remote, "the repaired handoff names the photo for the trash")
        XCTAssertTrue(movedOn.needsRemoteTrash)
        XCTAssertNil(movedOn.remoteOperation)
        XCTAssertEqual(movedOn.attempts, 0)

        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [movedOn]), [key])
        XCTAssertTrue(
            store.completeEffect(.remoteTrash, for: key, generation: 1, remoteLinkID: remote.nodeID, at: retry))
        let done = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertTrue(done.remoteTrashed)
        XCTAssertFalse(done.needsRemoteTrash, "the edit goes to the trash once")
        XCTAssertTrue(store.dueSourceStates(by: retry.addingTimeInterval(86_400)).isEmpty)
    }

    func testUndoDuringATrashRequestRestoresEvenAfterACrash() throws {
        let excluded = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: remote)], at: date)
        )
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: excluded), [key])

        // Undo arrives while the trash request is on the wire; the app then ends before completion.
        let restored = try XCTUnwrap(store.include([key], at: date)).first
        XCTAssertEqual(restored?.needsRemoteRestore, true, "the trash may have happened, so a restore is owed")
        store.close()
        store = try XCTUnwrap(PendingBackupManifestStore(url: storeURL))
        let reopened = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertTrue(reopened.needsRemoteRestore)
        XCTAssertEqual(reopened.remoteOperation, .remoteTrash)
    }

    func testDeleteDuringARestoreRequestTrashesAgain() throws {
        _ = store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: remote)], at: date)
        _ = store.completeEffect(.remoteTrash, for: key, generation: 1, at: date)
        let included = try XCTUnwrap(store.include([key], at: date))
        XCTAssertEqual(store.beginRemoteOperation(.remoteRestore, for: included), [key])

        let deleted = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: nil)], at: date)
        ).first
        XCTAssertEqual(deleted?.needsRemoteTrash, true, "the restore may have happened, so a trash is owed")
    }

    func testStaleDispatchIsNeverMarkedOrSent() throws {
        let excluded = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: remote)], at: date)
        )
        // Undo lands while the reconciler still looks up the photos volume.
        _ = store.include([key], at: date)
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: excluded), [])
        XCTAssertNil(store.sourceState(for: key)?.remoteOperation)
    }

    func testDeferredEffectsBackOffAndBecomeDueAgain() throws {
        _ = store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: nil)], at: date)
        XCTAssertEqual(store.dueSourceStates(by: date).map(\.key), [key])
        XCTAssertTrue(store.deferEffects(for: key, at: date))
        XCTAssertTrue(store.dueSourceStates(by: date).isEmpty)
        XCTAssertEqual(store.nextEffectDate(), date.addingTimeInterval(60))
        XCTAssertEqual(store.dueSourceStates(by: date.addingTimeInterval(60)).map(\.key), [key])
    }

    func testRemovingATrashEntryKeepsTheExclusion() throws {
        _ = store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: nil)], at: date)
        XCTAssertTrue(store.unlistFromTrash([key], at: date))
        let state = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertFalse(state.listedInTrash)
        XCTAssertEqual(state.desired, .excluded)
    }

    // MARK: - Evidence and handoffs

    func testV105HandoffsKeepTheirInsertTimesAndReturnTheNewestRevisionAfterUpgrade() throws {
        let original = PendingHandoff(
            key: key, revision: UploadBackupRevision(rawValue: 1), remote: remote, kind: .uploaded, createdAt: date)
        let edit = PendingHandoff(
            key: key, revision: UploadBackupRevision(rawValue: 2),
            remote: PhotoUID(volumeID: "vol", nodeID: "edit"), kind: .uploaded, createdAt: date)
        let replay = PendingHandoff(
            key: key, revision: original.revision, remote: PhotoUID(volumeID: "vol", nodeID: "replayed-original"),
            kind: .uploaded, createdAt: date.addingTimeInterval(10))
        store.close()

        // Use the v1.0.5 conflict update. Today's API can update created_at when the remote link changes.
        // v1.0.5 PendingBackupStore.swift:113-124 sets created_at only on insert.
        try writeV105Handoffs([original, edit, replay])
        store = try XCTUnwrap(PendingBackupManifestStore(url: storeURL))

        XCTAssertEqual(store.handoffTime(for: key, revision: original.revision), date)
        XCTAssertEqual(store.handoffTime(for: key, revision: edit.revision), date)
        XCTAssertEqual(store.unacknowledgedHandoffs().count, 2)
        let latest = try XCTUnwrap(store.latestHandoffs(for: [key])[key])
        XCTAssertEqual(latest, edit, "Equal insert times must still select the newer date revision")
        XCTAssertEqual(
            store.handoffs(forRemoteLinkIDs: [replay.remote.nodeID]).first?.remote, replay.remote,
            "The old conflict write changes the receipt without moving its insert time")
    }

    private func writeV105Handoffs(_ handoffs: [PendingHandoff]) throws {
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(opened, SQLITE_OK)
        let db = try XCTUnwrap(handle)
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(
            db,
            """
            INSERT INTO handoff(source_kind, source_id, revision_us, remote_volume_id, remote_link_id,
                                kind, created_at, acknowledged)
            VALUES(?, ?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT(source_kind, source_id, revision_us) DO UPDATE SET
              acknowledged=CASE
                WHEN handoff.remote_volume_id=excluded.remote_volume_id
                 AND handoff.remote_link_id=excluded.remote_link_id THEN handoff.acknowledged
                ELSE 0
              END,
              remote_volume_id=excluded.remote_volume_id,
              remote_link_id=excluded.remote_link_id,
              kind=excluded.kind;
            """, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(prepared, SQLITE_OK)
        let stmt = try XCTUnwrap(statement)
        for handoff in handoffs {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            let transient = SQLiteStoreSchemaGate.transientDestructor
            sqlite3_bind_text(stmt, 1, handoff.key.kind.rawValue, -1, transient)
            sqlite3_bind_text(stmt, 2, handoff.key.identifier, -1, transient)
            sqlite3_bind_int64(stmt, 3, handoff.revision.rawValue)
            sqlite3_bind_text(stmt, 4, handoff.remote.volumeID, -1, transient)
            sqlite3_bind_text(stmt, 5, handoff.remote.nodeID, -1, transient)
            sqlite3_bind_text(stmt, 6, handoff.kind.rawValue, -1, transient)
            sqlite3_bind_double(stmt, 7, handoff.createdAt.timeIntervalSince1970)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        }
    }

    func testEvidenceAndHandoffsSurviveReopening() throws {
        let revision = UploadBackupRevision(rawValue: 42)
        XCTAssertTrue(store.recordUploadEvidence(key, revision: revision, at: date))
        let handoff = PendingHandoff(key: key, revision: revision, remote: remote, kind: .uploaded, createdAt: date)
        XCTAssertEqual(store.recordHandoff(handoff), .recorded)
        store.close()

        store = try XCTUnwrap(PendingBackupManifestStore(url: storeURL), "a current store reopens")
        XCTAssertEqual(store.evidenceRevisions(), [key: [revision]])
        XCTAssertEqual(store.unacknowledgedHandoffs(), [handoff])

        XCTAssertTrue(store.acknowledgeHandoffs([(key, revision)]))
        XCTAssertTrue(store.unacknowledgedHandoffs().isEmpty)
        XCTAssertEqual(store.latestHandoffs(for: [key])[key]?.acknowledged, true)
        XCTAssertEqual(store.handoffs(forRemoteLinkIDs: ["link-1"]).map(\.key), [key])
        XCTAssertTrue(store.pruneAcknowledgedHandoffs(olderThan: date.addingTimeInterval(1)))
        XCTAssertTrue(store.latestHandoffs(for: [key]).isEmpty)
    }

    func testTheHandoffRecordedLastIsTheCurrentOneWhenUndoReturnsToAnEarlierRevision() {
        let original = UploadBackupRevision(rawValue: 1)
        let edit = UploadBackupRevision(rawValue: 2)
        func handoff(_ revision: UploadBackupRevision, _ link: String, after seconds: TimeInterval) -> PendingHandoff {
            PendingHandoff(
                key: key, revision: revision, remote: PhotoUID(volumeID: "vol", nodeID: link), kind: .uploaded,
                createdAt: date.addingTimeInterval(seconds))
        }
        XCTAssertEqual(store.recordHandoff(handoff(original, "original", after: 0)), .recorded)
        XCTAssertEqual(store.recordHandoff(handoff(edit, "edit", after: 1)), .recorded)
        XCTAssertEqual(store.latestHandoffs(for: [key])[key]?.remote.nodeID, "edit")

        XCTAssertEqual(store.recordHandoff(handoff(original, "undone", after: 2)), .recorded)

        XCTAssertEqual(
            store.latestHandoffs(for: [key])[key]?.remote.nodeID, "undone",
            "an action of the person must reach the photo that replaced the edit")
    }

    func testAReplayedUploadRecordOfAnEarlierRevisionDoesNotBecomeTheCurrentHandoff() {
        func handoff(_ revision: Int64, _ link: String, after seconds: TimeInterval) -> PendingHandoff {
            PendingHandoff(
                key: key, revision: UploadBackupRevision(rawValue: revision),
                remote: PhotoUID(volumeID: "vol", nodeID: link), kind: .uploaded,
                createdAt: date.addingTimeInterval(seconds))
        }
        XCTAssertEqual(store.recordHandoff(handoff(1, "earlier", after: 0)), .recorded)
        XCTAssertEqual(store.recordHandoff(handoff(2, "current", after: 1)), .recorded)

        // The receipt of the earlier upload settles late and records its photo again.
        XCTAssertEqual(store.recordHandoff(handoff(1, "earlier", after: 2)), .recorded)

        XCTAssertEqual(store.latestHandoffs(for: [key])[key]?.remote.nodeID, "current")
        XCTAssertEqual(store.handoffTime(for: key, revision: UploadBackupRevision(rawValue: 1)), date)
    }

    func testPendingHealthDoesNotProbeDeniedSelect() throws {
        XCTAssertTrue(store.isOperational())
        try withDeniedSQLiteSelect(in: store!) {
            XCTAssertTrue(store.isOperational(), "pending health checks only connection state")
        }
        XCTAssertTrue(store.isOperational(), "denied SELECT must not record a new failure")
    }

    func testPendingCloseRefusesRealWritesAndPreservesEmptyNoOpsAndRows() throws {
        let revision = UploadBackupRevision(rawValue: 10)
        XCTAssertTrue(store.recordUploadEvidence(key, revision: revision, at: date))
        let states = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: nil)], at: date))
        store.close()
        XCTAssertFalse(store.isOperational())
        XCTAssertTrue(store.removeEvidence([(PendingSourceKey, UploadBackupRevision)]()))
        XCTAssertTrue(store.acknowledgeHandoffs([]))
        XCTAssertTrue(store.unlistFromTrash([], at: date))
        XCTAssertEqual(store.exclusions(kind: .photoLibraryAsset, among: []), [:])
        XCTAssertEqual(store.exclude([], at: date), [])
        XCTAssertEqual(store.include([], at: date), [])
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: []), [])
        XCTAssertEqual(store.beginRemoteOperation(.queueSync, for: states), [])
        XCTAssertTrue(store.latestHandoffs(for: []).isEmpty)
        XCTAssertTrue(store.handoffs(forRemoteLinkIDs: []).isEmpty)
        XCTAssertFalse(store.recordUploadEvidence(key, revision: UploadBackupRevision(rawValue: 20), at: date))
        XCTAssertTrue(store.evidenceRevisions().isEmpty)
        XCTAssertFalse(store.isOperational())
        store = try XCTUnwrap(PendingBackupManifestStore(url: storeURL))
        XCTAssertEqual(store.evidenceRevisions(), [key: [revision]])
        XCTAssertEqual(store.sourceStates(), states)
        XCTAssertEqual(store.sourceState(for: key)?.desired, .excluded)
        XCTAssertTrue(store.isOperational())
    }

    /// A lasting failure refuses further standalone writes; successful reads cannot clear it (#1005).
    func testANonTransientFailureStaysStickyAndRefusesFurtherWrites() throws {
        XCTAssertTrue(store.setFavoriteIntent(key, favorite: true, at: date))
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: nil)], at: date))
        try withOneDeniedSourceSelect { _ = store.actions() }
        XCTAssertFalse(store.isOperational())
        let revision = UploadBackupRevision(rawValue: 10)
        XCTAssertFalse(store.recordUploadEvidence(key, revision: revision, at: date))
        XCTAssertTrue(store.evidenceRevisions().isEmpty)
        XCTAssertFalse(store.isOperational(), "successful SQL cannot clear a failure that is not transient")
        XCTAssertNil(
            store.exclusions(kind: .photoLibraryAsset, among: [key.identifier]),
            "a lasting failure stops the exclusion read, so no photo uploads while its exclusion is unknown")
    }

    /// A transaction that stays open can hold half a write; the exclusion read does not answer from it (#982).
    func testAnOpenTransactionStopsTheExclusionRead() throws {
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: nil)], at: date))
        let connection = try pendingConnection()
        connection.withLock {
            XCTAssertEqual(sqlite3_exec(connection.database, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertNil(store.exclusions(kind: .photoLibraryAsset, among: [key.identifier]))
        connection.withLock {
            XCTAssertEqual(sqlite3_exec(connection.database, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(store.exclusions(kind: .photoLibraryAsset, among: [key.identifier]), [key.identifier: .excluded])
    }

    /// A COMMIT that fails ends the transaction and records the failure with the code of the COMMIT (#982).
    func testAFailedCommitWritesNothingAndStopsTheStore() throws {
        let connection = try pendingConnection()
        let before = try pendingTables()
        connection.withLock { _ = sqlite3_commit_hook(connection.database, { _ in 1 }, nil) }

        XCTAssertNil(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: nil)], at: date))

        connection.withLock {
            _ = sqlite3_commit_hook(connection.database, nil, nil)
            XCTAssertNotEqual(sqlite3_get_autocommit(connection.database), 0, "no transaction stays open")
            XCTAssertTrue(connection.operationFailed)
            XCTAssertFalse(connection.failuresAreTransient, "a refused commit is not a passing failure")
        }
        XCTAssertFalse(store.isOperational())
        XCTAssertEqual(try pendingTables(), before, "nothing was written")
    }

    /// A favorite intent that a newer build wrote with a kind that this build does not know (#982).
    func testAPendingActionThatCannotBeDecodedStopsNothingAndStaysUnchanged() throws {
        XCTAssertTrue(store.setFavoriteIntent(key, favorite: true, at: date))
        try withRawPendingDatabase {
            XCTAssertEqual(sqlite3_exec($0, "UPDATE pending_action SET kind='invalid-kind';", nil, nil, nil), SQLITE_OK)
        }
        let before = try pendingTables()

        XCTAssertFalse(store.actionsRead().complete, "the read stays incomplete")
        XCTAssertTrue(store.isOperational())
        let revision = UploadBackupRevision(rawValue: 10)
        XCTAssertTrue(store.recordUploadEvidence(key, revision: revision, at: date))

        XCTAssertEqual(try pendingTables()["pending_action"], before["pending_action"], "the row stays unchanged")
    }

    // MARK: - A row that does not decode, or one failed call, stops nothing else (#982)

    private let other = PendingSourceKey(kind: .photoLibraryAsset, identifier: "asset-2")

    /// Excludes `key` and `other` without a remote photo, so both are listed in Recently Deleted.
    private func excludeBoth() {
        XCTAssertNotNil(
            store.exclude(
                [key, other].map { PendingExclusionRequest(key: $0, presentation: presentation(), remote: nil) },
                at: date))
    }

    private func corrupt(_ column: String, of identifier: String = "asset-1") throws {
        try withRawPendingDatabase {
            XCTAssertEqual(
                sqlite3_exec(
                    $0, "UPDATE source_state SET \(column)='written-by-a-newer-build' WHERE source_id='\(identifier)';",
                    nil, nil, nil), SQLITE_OK)
        }
    }

    /// A newer build may have excluded the photo: its identifier is reported unreadable, never included.
    func testAnIdentifierWithARowThatCannotBeDecodedIsReportedUnreadable() throws {
        for column in ["source_kind", "desired", "remote_op"] {
            XCTAssertNotNil(
                store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: nil)], at: date))
            try corrupt(column)
            let before = try pendingTables()

            XCTAssertEqual(
                store.exclusions(kind: .photoLibraryAsset, among: ["asset-1", "asset-2"]), ["asset-1": .unreadable],
                column)
            XCTAssertTrue(store.isOperational(), column)
            XCTAssertFalse(store.sourceStatesRead().complete, "the read stays incomplete (\(column))")
            XCTAssertEqual(try pendingTables(), before, "the row stays unchanged (\(column))")

            try withRawPendingDatabase {
                XCTAssertEqual(
                    sqlite3_exec(
                        $0, "DELETE FROM source_state; DELETE FROM pending_info WHERE key GLOB 'pending-trash:*';", nil,
                        nil, nil), SQLITE_OK)
            }
        }
    }

    /// An excluded row of another kind does not exclude the photo; an unreadable row of the same identifier wins over
    /// an excluded row, so the photo waits instead of being removed (#982).
    func testExclusionsCountOnlyTheRequestedKindAndAnUnreadableRowWins() throws {
        let fileKey = PendingSourceKey(kind: .fileURL, identifier: key.identifier)
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: fileKey, presentation: presentation(), remote: nil)], at: date))
        XCTAssertEqual(store.exclusions(kind: .photoLibraryAsset, among: [key.identifier]), [:])

        // The unreadable kind sorts before the excluded row, by row and by key, so the read meets it first.
        try withRawPendingDatabase {
            XCTAssertEqual(
                sqlite3_exec($0, "UPDATE source_state SET source_kind='a-newer-kind';", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: nil)], at: date))
        XCTAssertEqual(
            store.exclusions(kind: .photoLibraryAsset, among: [key.identifier]), [key.identifier: .unreadable])

        // The other order: the excluded row comes first, by row and by key, and the unreadable row after it.
        try withRawPendingDatabase {
            XCTAssertEqual(
                sqlite3_exec(
                    $0, "DELETE FROM source_state; DELETE FROM pending_info WHERE key GLOB 'pending-trash:*';", nil,
                    nil, nil), SQLITE_OK)
        }
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: nil)], at: date))
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: fileKey, presentation: presentation(), remote: nil)], at: date))
        try withRawPendingDatabase {
            XCTAssertEqual(
                sqlite3_exec(
                    $0, "UPDATE source_state SET source_kind='zz-newer-kind' WHERE source_kind='fileURL';", nil, nil,
                    nil), SQLITE_OK)
        }
        XCTAssertEqual(
            store.exclusions(kind: .photoLibraryAsset, among: [key.identifier]), [key.identifier: .unreadable])

        // A row of a known kind whose other value cannot be read; the key read meets it before the excluded row.
        try withRawPendingDatabase {
            XCTAssertEqual(
                sqlite3_exec(
                    $0,
                    "UPDATE source_state SET source_kind='fileURL', desired='written-by-a-newer-build' "
                        + "WHERE source_kind='zz-newer-kind';", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(
            store.exclusions(kind: .photoLibraryAsset, among: [key.identifier]), [key.identifier: .unreadable])
    }

    /// The read finds a row of an unknown kind before, between and after the kinds that this build knows (#982).
    func testARowOfAnUnknownKindIsFoundInEveryGapBetweenTheKnownKinds() throws {
        for unknownKind in ["a-newer-kind", "m-newer-kind", "zz-newer-kind"] {
            XCTAssertNotNil(
                store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: nil)], at: date))
            try withRawPendingDatabase {
                XCTAssertEqual(
                    sqlite3_exec($0, "UPDATE source_state SET source_kind='\(unknownKind)';", nil, nil, nil), SQLITE_OK)
            }

            XCTAssertEqual(
                store.exclusions(kind: .photoLibraryAsset, among: [key.identifier]), [key.identifier: .unreadable],
                unknownKind)

            try withRawPendingDatabase {
                XCTAssertEqual(
                    sqlite3_exec(
                        $0, "DELETE FROM source_state; DELETE FROM pending_info WHERE key GLOB 'pending-trash:*';", nil,
                        nil, nil), SQLITE_OK)
            }
        }
    }

    func testUnlistingFromTheTrashLeavesARowThatCannotBeDecodedUnchanged() throws {
        excludeBoth()
        try corrupt("desired")
        let corrupted = try XCTUnwrap(try pendingTables()["source_state"]?.first)

        XCTAssertTrue(store.unlistFromTrash([key, other], at: date.addingTimeInterval(5)))

        XCTAssertEqual(try pendingTables()["source_state"]?.first, corrupted, "the row stays unchanged")
        XCTAssertEqual(store.sourceState(for: other)?.listedInTrash, false, "the other row is unlisted")
        XCTAssertTrue(store.isOperational())
    }

    func testAHandoffThatCannotBeDecodedIsNeitherReplacedNorPrunedNorIgnored() throws {
        let revision = UploadBackupRevision(rawValue: 7)
        let handoff = PendingHandoff(key: key, revision: revision, remote: remote, kind: .uploaded, createdAt: date)
        XCTAssertEqual(store.recordHandoff(handoff), .recorded)
        XCTAssertTrue(store.acknowledgeHandoffs([(key, revision)]))
        try withRawPendingDatabase {
            XCTAssertEqual(
                sqlite3_exec($0, "UPDATE handoff SET kind='written-by-a-newer-build';", nil, nil, nil), SQLITE_OK)
        }
        let before = try pendingTables()

        XCTAssertEqual(store.recordHandoff(handoff), .failed, "a newer handoff of this revision is not replaced")
        XCTAssertNil(
            store.exclude(
                [PendingExclusionRequest(key: key, presentation: nil, remote: nil, revision: revision)],
                at: date.addingTimeInterval(1)),
            "an exclusion cannot tell which photo the revision committed")
        XCTAssertTrue(store.pruneAcknowledgedHandoffs(olderThan: date.addingTimeInterval(3_600)))

        XCTAssertEqual(try pendingTables(), before, "every row stays unchanged")
        XCTAssertTrue(store.isOperational())
    }

    func testPruningKeepsTheHandoffsOfASourceWithARowThatCannotBeDecoded() throws {
        excludeBoth()
        for target in [key, other] {
            let revision = UploadBackupRevision(rawValue: 7)
            let handoff = PendingHandoff(
                key: target, revision: revision, remote: remote, kind: .uploaded, createdAt: date)
            XCTAssertNotEqual(store.recordHandoff(handoff), .failed)
            XCTAssertTrue(store.acknowledgeHandoffs([(target, revision)]))
        }
        XCTAssertNotNil(store.include([key, other], at: date))
        try corrupt("desired")

        XCTAssertTrue(store.pruneAcknowledgedHandoffs(olderThan: date.addingTimeInterval(3_600)))

        let kept = try XCTUnwrap(try pendingTables()["handoff"])
        XCTAssertEqual(kept.count, 1, "only the handoff of the unreadable source stays")
        XCTAssertEqual(kept.first?.first, Data("photoLibraryAsset".utf8))
        XCTAssertEqual(kept.first?[1], Data("asset-1".utf8))
    }

    /// Another connection holds the write lock until its busy timeout ends, as a full disk or a busy database does.
    /// The write fails; once the lock is free, the store works again without a reopen.
    func testATransientWriteFailureStopsTheStoreOnlyUntilTheDatabaseAnswers() throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let blocker = try XCTUnwrap(handle)
        defer { sqlite3_close(blocker) }
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)

        XCTAssertFalse(store.recordUploadEvidence(key, revision: UploadBackupRevision(rawValue: 1), at: date))
        XCTAssertEqual(
            store.exclusions(kind: .photoLibraryAsset, among: [key.identifier]), [:],
            "a transient failure does not stop the exclusion read")

        XCTAssertEqual(sqlite3_exec(blocker, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(store.isOperational(), "the database answers again")
        XCTAssertTrue(store.recordUploadEvidence(key, revision: UploadBackupRevision(rawValue: 1), at: date))
    }

    /// An upload record for a photo whose pending row cannot be read is refused, so a copy that Proton already holds
    /// changes nothing in the store (#982).
    func testAHandoffForAPhotoWithAnUnreadableRowIsRefused() throws {
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: nil)], at: date))
        try corrupt("desired")
        let before = try pendingTables()

        let handoff = PendingHandoff(
            key: key, revision: UploadBackupRevision(rawValue: 7), remote: remote, kind: .deduplicated, createdAt: date)
        XCTAssertEqual(store.recordHandoff(handoff), .failed)

        XCTAssertEqual(try pendingTables(), before, "every row stays unchanged")
    }

    func testKeepingAPhotoRefusesAHandoffThatCannotBeDecoded() throws {
        let revision = UploadBackupRevision(rawValue: 7)
        let excluded = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: remote)], at: date)?
                .first)
        let handoff = PendingHandoff(key: key, revision: revision, remote: remote, kind: .uploaded, createdAt: date)
        XCTAssertNotEqual(store.recordHandoff(handoff), .failed)
        try withRawPendingDatabase {
            XCTAssertEqual(
                sqlite3_exec($0, "UPDATE handoff SET kind='written-by-a-newer-build';", nil, nil, nil), SQLITE_OK)
        }
        let before = try pendingTables()

        XCTAssertNil(
            store.keepRemote(
                remote, of: key, generation: excluded.generation, revision: revision, at: date.addingTimeInterval(2)),
            "keeping a photo cannot tell which photo the revision committed")

        XCTAssertEqual(try pendingTables(), before, "every row stays unchanged")
    }

    /// The exclusions of a large batch are read in chunks; an excluded photo and an unreadable row in the last chunk
    /// still count, and a repeated identifier counts once.
    func testExclusionsOfAMoreThanFiveHundredPhotoBatchReadEveryChunk() throws {
        let identifiers = (0..<1_001).map { "asset-\($0)" }
        let lastExcluded = PendingSourceKey(kind: .photoLibraryAsset, identifier: "asset-1000")
        let lastUnreadable = PendingSourceKey(kind: .photoLibraryAsset, identifier: "asset-999")
        XCTAssertNotNil(
            store.exclude(
                [lastExcluded, lastUnreadable].map {
                    PendingExclusionRequest(key: $0, presentation: presentation(), remote: nil)
                }, at: date))
        try corrupt("desired", of: "asset-999")

        let answer = try XCTUnwrap(
            store.exclusions(kind: .photoLibraryAsset, among: identifiers + ["asset-1000", "asset-999"]))

        XCTAssertEqual(answer, ["asset-1000": .excluded, "asset-999": .unreadable])
        XCTAssertEqual(
            store.exclusions(kind: .photoLibraryAsset, among: identifiers),
            ["asset-999": .unreadable, "asset-1000": .excluded])
    }

    /// A failed read of a row fails the unlisting; only a row that does not decode is skipped.
    func testAFailedReadFailsTheUnlistingFromTheTrash() throws {
        excludeBoth()
        try withOneDeniedSourceSelect {
            XCTAssertFalse(store.unlistFromTrash([key, other], at: date.addingTimeInterval(5)))
        }
        XCTAssertEqual(store.sourceState(for: other)?.listedInTrash, true, "the batch rolled back")
    }

    /// Writers that change a row which a caller read earlier leave it as it is when it no longer decodes.
    func testAcknowledgingAndStartingRemoteWorkLeaveARowThatCannotBeDecodedUnchanged() throws {
        let revision = UploadBackupRevision(rawValue: 7)
        let excluded = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: remote)], at: date))
        XCTAssertNotEqual(
            store.recordHandoff(
                PendingHandoff(key: key, revision: revision, remote: remote, kind: .uploaded, createdAt: date)),
            .failed)
        try withRawPendingDatabase {
            XCTAssertEqual(
                sqlite3_exec($0, "UPDATE handoff SET kind='written-by-a-newer-build';", nil, nil, nil), SQLITE_OK)
        }
        try corrupt("remote_op")
        let before = try pendingTables()

        XCTAssertTrue(store.acknowledgeHandoffs([(key, revision)]))
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: excluded), [])

        XCTAssertEqual(try pendingTables(), before, "every row stays unchanged")
    }

    func testAHandoffThatCannotBeDecodedIsCounted() throws {
        let revision = UploadBackupRevision(rawValue: 7)
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(key: key, revision: revision, remote: remote, kind: .uploaded, createdAt: date)),
            .recorded)
        try withRawPendingDatabase {
            XCTAssertEqual(
                sqlite3_exec($0, "UPDATE handoff SET kind='written-by-a-newer-build';", nil, nil, nil), SQLITE_OK)
        }
        let before = PhotoDiagnostics.shared.counter("pending.undecodableRow")

        XCTAssertEqual(store.latestHandoffsRead(for: [key])[key], .unreadable)

        XCTAssertEqual(PhotoDiagnostics.shared.counter("pending.undecodableRow"), before + 1)
    }

    /// Each read of the exclusions fails closed on its own failure.
    func testAFailedExclusionReadAnswersNil() throws {
        try withOneDeniedSourceSelect {
            XCTAssertNil(store.exclusions(kind: .photoLibraryAsset, among: ["asset-1"]))
        }
    }

    func testClosedStoreCannotConfirmExclusions() {
        store.close()
        XCTAssertNil(store.exclusions(kind: .photoLibraryAsset, among: ["asset-1"]))
        XCTAssertFalse(store.isOperational())
    }

    // MARK: - Deferred actions

    func testFavoriteToggleReplacesTheEarlierRequest() throws {
        XCTAssertTrue(store.setFavoriteIntent(key, favorite: true, at: date))
        let first = try XCTUnwrap(store.actions().first)
        XCTAssertTrue(store.setFavoriteIntent(key, favorite: false, at: date.addingTimeInterval(1)))

        XCTAssertTrue(store.completeAction(first), "completing a replaced request is harmless")
        XCTAssertEqual(store.actions().map(\.desired), [false], "the newer request survives")
    }

    func testFailedActionRetriesWithBackoffUntilPermanentlyFailed() throws {
        XCTAssertTrue(store.addAlbumIntent(key, albumID: "album-1", at: date))
        let action = try XCTUnwrap(store.actions().first)
        XCTAssertTrue(store.retryAction(action, at: date))
        XCTAssertTrue(store.dueActions(by: date).isEmpty)
        XCTAssertEqual(store.actions().first?.nextAttemptAt, date.addingTimeInterval(60))
        XCTAssertEqual(store.dueActions(by: date.addingTimeInterval(60)).count, 1)

        XCTAssertTrue(store.failAction(action))
        XCTAssertTrue(store.dueActions(by: date.addingTimeInterval(1_000_000)).isEmpty)
        XCTAssertEqual(store.actions().first?.failed, true)
    }

    func testStaleActionOutcomeNeverTouchesTheNewerRequest() throws {
        XCTAssertTrue(store.setFavoriteIntent(key, favorite: true, at: date))
        let first = try XCTUnwrap(store.actions().first)
        XCTAssertTrue(store.setFavoriteIntent(key, favorite: false, at: date.addingTimeInterval(1)))

        XCTAssertTrue(store.failAction(first))
        XCTAssertTrue(store.retryAction(first, at: date))
        let current = try XCTUnwrap(store.actions().first)
        XCTAssertFalse(current.failed)
        XCTAssertEqual(current.attempts, 0)
        XCTAssertFalse(current.desired)
    }

    func testHandoffOfAnUnfinishedActionSurvivesPruning() throws {
        let revision = UploadBackupRevision(rawValue: 1)
        let handoff = PendingHandoff(key: key, revision: revision, remote: remote, kind: .uploaded, createdAt: date)
        _ = store.recordHandoff(handoff)
        _ = store.acknowledgeHandoffs([(key, revision)])
        XCTAssertTrue(store.addAlbumIntent(key, albumID: "album", at: date))

        XCTAssertTrue(store.pruneAcknowledgedHandoffs(olderThan: date.addingTimeInterval(1)))
        XCTAssertEqual(store.latestHandoffs(for: [key])[key]?.remote, remote)
    }

    func testSavedFromAppIdentifiersPersist() {
        XCTAssertTrue(store.recordSavedFromApp(localIdentifier: "saved-1", remote: remote, at: date))
        XCTAssertEqual(store.savedFromAppIdentifiers(), ["saved-1"])
    }

    // MARK: - Latest handoffs of many sources

    /// One call answers each source exactly as a call for that source alone does: the newest handoff, an absent
    /// handoff, and an unreadable row that leaves the sources after it readable.
    func testLatestHandoffsAnswerEachSourceAsItsOwnReadDoes() throws {
        func source(_ name: String) -> PendingSourceKey { PendingSourceKey(kind: .photoLibraryAsset, identifier: name) }
        func handoff(
            _ source: PendingSourceKey, revision: Int64, link: String, at offset: TimeInterval
        )
            -> PendingHandoff
        {
            PendingHandoff(
                key: source, revision: UploadBackupRevision(rawValue: revision),
                remote: PhotoUID(volumeID: "vol", nodeID: link), kind: .uploaded,
                createdAt: date.addingTimeInterval(offset))
        }
        let edited = source("edited")
        let absent = source("absent")
        let damaged = source("damaged")
        let plain = source("plain")
        XCTAssertEqual(store.recordHandoff(handoff(edited, revision: 7, link: "edited-old", at: 0)), .recorded)
        XCTAssertEqual(store.recordHandoff(handoff(edited, revision: 8, link: "edited-new", at: 60)), .recorded)
        XCTAssertEqual(store.recordHandoff(handoff(damaged, revision: 7, link: "damaged", at: 0)), .recorded)
        XCTAssertEqual(store.recordHandoff(handoff(plain, revision: 7, link: "plain", at: 0)), .recorded)
        try withRawPendingDatabase {
            XCTAssertEqual(
                sqlite3_exec($0, "UPDATE handoff SET kind='invalid' WHERE source_id='damaged';", nil, nil, nil),
                SQLITE_OK)
        }
        let keys = [damaged, edited, absent, plain]

        let together = store.latestHandoffsRead(for: keys)

        XCTAssertEqual(
            together,
            [
                damaged: .unreadable,
                edited: .readable(handoff(edited, revision: 8, link: "edited-new", at: 60)),
                absent: .readable(nil),
                plain: .readable(handoff(plain, revision: 7, link: "plain", at: 0)),
            ])
        for key in keys {
            XCTAssertEqual(store.latestHandoffsRead(for: [key]), [key: together[key]!], "\(key.identifier) alone")
        }
        XCTAssertEqual(store.latestHandoffsRead(for: []), [:])

        store.close()
        XCTAssertEqual(
            store.latestHandoffsRead(for: [edited, plain]), [edited: .unreadable, plain: .unreadable],
            "a closed store reads nothing")
    }

    // MARK: - Text that does not round-trip

    func testHandoffReadRejectsAnEmbeddedNULRemoteVolumeID() throws {
        let healthy = PendingSourceKey(kind: .photoLibraryAsset, identifier: "asset-0")
        for (source, link) in [(healthy, "link-0"), (key, "link-1")] {
            XCTAssertEqual(
                store.recordHandoff(
                    PendingHandoff(
                        key: source, revision: UploadBackupRevision(rawValue: 7),
                        remote: PhotoUID(volumeID: "vol", nodeID: link), kind: .uploaded, createdAt: date)),
                .recorded)
        }
        let marker = "vol\u{0}written-by-a-newer-build"
        try bindRawText(marker, "UPDATE handoff SET remote_volume_id=? WHERE source_id='\(key.identifier)';")
        let before = try pendingTables()
        XCTAssertEqual(
            try storedBytes(of: "remote_volume_id", in: "handoff", kind: key.kind, identifier: key.identifier),
            Data(marker.utf8))

        let reads = store.latestHandoffsRead(for: [healthy, key])

        XCTAssertEqual(reads[healthy]?.handoff?.remote, PhotoUID(volumeID: "vol", nodeID: "link-0"))
        XCTAssertEqual(reads[key], .unreadable, "a decoded prefix must not become a shorter volume ID")
        XCTAssertEqual(store.handoffsRead(forRemoteLinkIDs: [remote.nodeID]), .unreadable)
        XCTAssertEqual(try pendingTables(), before, "a rejected row must stay as it is")
    }

    func testReverseHandoffLookupRejectsAnEmbeddedNULSourceID() throws {
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(
                    key: key, revision: UploadBackupRevision(rawValue: 7), remote: remote, kind: .uploaded,
                    createdAt: date)), .recorded)
        let marker = "\(key.identifier)\u{0}written-by-a-newer-build"
        try bindRawText(marker, "UPDATE handoff SET source_id=? WHERE source_id='\(key.identifier)';")
        let before = try pendingTables()
        XCTAssertEqual(
            try storedBytes(of: "source_id", in: "handoff", kind: key.kind, identifier: marker), Data(marker.utf8))

        XCTAssertEqual(store.handoffsRead(forRemoteLinkIDs: [remote.nodeID]), .unreadable)
        XCTAssertEqual(try pendingTables(), before, "a rejected row must stay as it is")
    }

    func testHandoffReadRejectsInvalidUTF8RemoteVolumeID() throws {
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(
                    key: key, revision: UploadBackupRevision(rawValue: 7), remote: remote, kind: .uploaded,
                    createdAt: date)), .recorded)
        try withRawPendingDatabase {
            XCTAssertEqual(
                sqlite3_exec($0, "UPDATE handoff SET remote_volume_id=CAST(x'766F6CFF' AS TEXT);", nil, nil, nil),
                SQLITE_OK)
        }
        let before = try pendingTables()
        XCTAssertEqual(
            try storedBytes(of: "remote_volume_id", in: "handoff", kind: key.kind, identifier: key.identifier),
            Data([0x76, 0x6F, 0x6C, 0xFF]))

        XCTAssertEqual(store.latestHandoffsRead(for: [key])[key], .unreadable, "invalid UTF-8 does not round-trip")
        XCTAssertEqual(try pendingTables(), before, "a rejected row must stay as it is")
    }

    func testActionReadRejectsAnEmbeddedNULAlbumID() throws {
        let healthyFavorite = PendingSourceKey(kind: .photoLibraryAsset, identifier: "asset-0")
        let healthyAlbum = PendingSourceKey(kind: .photoLibraryAsset, identifier: "asset-2")
        XCTAssertTrue(store.setFavoriteIntent(healthyFavorite, favorite: true, at: date))
        XCTAssertTrue(store.addAlbumIntent(healthyAlbum, albumID: "album-9", at: date))
        XCTAssertTrue(store.addAlbumIntent(key, albumID: "album-1", at: date))
        let marker = "album-1\u{0}written-by-a-newer-build"
        try bindRawText(marker, "UPDATE pending_action SET album_id=? WHERE source_id='\(key.identifier)';")
        let before = try pendingTables()
        XCTAssertEqual(
            try storedBytes(of: "album_id", in: "pending_action", kind: key.kind, identifier: key.identifier),
            Data(marker.utf8))

        let read = store.actionsRead()

        XCTAssertEqual(read.complete, false, "a rejected row makes the read incomplete")
        XCTAssertEqual(
            Set(read.actions.map(\.key)), [healthyFavorite, healthyAlbum], "a decoded prefix must not pass")
        XCTAssertEqual(read.actions.first(where: { $0.key == healthyFavorite })?.albumID, "")
        XCTAssertEqual(read.actions.first(where: { $0.key == healthyAlbum })?.albumID, "album-9")
        XCTAssertEqual(try pendingTables(), before, "a rejected row must stay as it is")
    }

    func testActionReadRejectsAnEmbeddedNULSourceID() throws {
        let healthy = PendingSourceKey(kind: .photoLibraryAsset, identifier: "asset-0")
        XCTAssertTrue(store.setFavoriteIntent(healthy, favorite: true, at: date))
        XCTAssertTrue(store.setFavoriteIntent(key, favorite: true, at: date))
        let marker = "\(key.identifier)\u{0}written-by-a-newer-build"
        try bindRawText(marker, "UPDATE pending_action SET source_id=? WHERE source_id='\(key.identifier)';")
        let before = try pendingTables()
        XCTAssertEqual(
            try storedBytes(of: "source_id", in: "pending_action", kind: key.kind, identifier: marker),
            Data(marker.utf8))

        let read = store.actionsRead()

        XCTAssertEqual(read.complete, false, "a rejected row makes the read incomplete")
        XCTAssertEqual(read.actions.map(\.key), [healthy], "a decoded prefix must not become a shorter source ID")
        XCTAssertEqual(try pendingTables(), before, "a rejected row must stay as it is")
    }

    func testAHandoffTextColumnThatDoesNotRoundTripIsCounted() throws {
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(
                    key: key, revision: UploadBackupRevision(rawValue: 7), remote: remote, kind: .uploaded,
                    createdAt: date)), .recorded)
        try bindRawText(
            "vol\u{0}written-by-a-newer-build",
            "UPDATE handoff SET remote_volume_id=? WHERE source_id='\(key.identifier)';")
        let counted = PhotoDiagnostics.shared.counter("pending.undecodableRow")

        XCTAssertEqual(store.latestHandoffsRead(for: [key])[key], .unreadable)

        XCTAssertEqual(PhotoDiagnostics.shared.counter("pending.undecodableRow"), counted + 1)
        XCTAssertTrue(store.isOperational(), "a rejected row is not a store failure")
    }

    func testAnActionTextColumnThatDoesNotRoundTripIsCounted() throws {
        XCTAssertTrue(store.setFavoriteIntent(key, favorite: true, at: date))
        try bindRawText(
            "favorite\u{0}written-by-a-newer-build",
            "UPDATE pending_action SET kind=? WHERE source_id='\(key.identifier)';")
        let counted = PhotoDiagnostics.shared.counter("pending.undecodableRow")

        XCTAssertEqual(store.actionsRead().complete, false)

        XCTAssertEqual(PhotoDiagnostics.shared.counter("pending.undecodableRow"), counted + 1)
        XCTAssertTrue(store.isOperational(), "a rejected row is not a store failure")
    }
}

final class PendingQueueIntegrationTests: XCTestCase {
    private var directory: URL!
    private var queue: UploadBackupSyncQueueManifestStore!
    private let date = Date(timeIntervalSince1970: 1_750_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-queue-\(UUID().uuidString)", isDirectory: true)
        queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
    }

    override func tearDownWithError() throws {
        queue.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func entry(_ id: String, state: UploadBackupSyncQueueState) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id, resource: .primary),
            revision: UploadBackupRevision(rawValue: 7),
            originalFilename: "\(id).heic",
            state: state,
            updatedAt: date
        )
    }

    func testQueueWritesNotifyTheObserverAfterTheyCommit() {
        let changes = LockedChanges()
        queue.setChangeObserver { changes.append($0) }

        XCTAssertTrue(queue.upsert(entry("a", state: .discovered)))
        XCTAssertTrue(
            queue.updateState(
                source: entry("a", state: .discovered).source,
                revision: UploadBackupRevision(rawValue: 7),
                state: .queuedForUpload,
                attempts: nil,
                lastError: nil,
                updatedAt: date
            ))
        XCTAssertEqual(queue.removeSources(kind: .photoLibraryAsset, identifiers: ["a"]), 1)
        XCTAssertEqual(queue.makeRetryableWorkEligible(updatedAt: date), 0, "an empty bulk update stays silent")

        let expected = UploadBackupSyncQueueChange.sources([.photoLibraryAsset: ["a"]])
        XCTAssertEqual(changes.values, [.enqueued([.photoLibraryAsset: ["a"]]), expected, expected])
    }

    func testOnlyInsertedOrReopenedRowsNotifyAnEnqueue() {
        let changes = LockedChanges()
        queue.setChangeObserver { changes.append($0) }
        let runnable = entry("a", state: .discovered)
        let sources: [UploadSourceIdentity.Kind: Set<String>] = [.photoLibraryAsset: ["a"]]

        XCTAssertTrue(queue.upsert(runnable))
        XCTAssertTrue(queue.upsert(runnable), "a repeated scan does not add work")
        XCTAssertTrue(queue.upsert(entry("a", state: .completed)))
        XCTAssertTrue(queue.upsertBatch([runnable]), "a scan cannot reopen a successful row")
        XCTAssertEqual(try queue.entry(for: runnable.source, revision: runnable.revision)?.state, .completed)
        XCTAssertEqual(changes.values, [.enqueued(sources), .sources(sources), .sources(sources), .sources(sources)])

        let failed = entry("b", state: .failed)
        XCTAssertTrue(queue.upsert(failed))
        XCTAssertTrue(queue.upsertBatch([entry("b", state: .discovered)]))
        XCTAssertEqual(changes.values.last, .enqueued([.photoLibraryAsset: ["b"]]))

        XCTAssertTrue(queue.upsert(entry("active", state: .uploading)))
        XCTAssertTrue(queue.upsert(entry("active", state: .needsRemoteReconciliation)))
        XCTAssertEqual(changes.values.last, .sources([.photoLibraryAsset: ["active"]]))
        XCTAssertEqual(
            try queue.entry(for: entry("active", state: .uploading).source, revision: runnable.revision)?.state,
            .uploading)

        var delayed = entry("waiting", state: .discovered)
        delayed.updatedAt = date.addingTimeInterval(60)
        XCTAssertTrue(queue.upsert(delayed))
        XCTAssertTrue(queue.upsert(entry("waiting", state: .discovered)))
        XCTAssertEqual(changes.values.last, .enqueued([.photoLibraryAsset: ["waiting"]]))
    }

    func testMissingSourceInsertsNotifyOnlyNewRunnableRows() {
        let changes = LockedChanges()
        queue.setChangeObserver { changes.append($0) }
        let runnable = entry("a", state: .discovered)
        let sources: [UploadSourceIdentity.Kind: Set<String>] = [.photoLibraryAsset: ["a"]]

        XCTAssertTrue(queue.insertMissingSources([runnable]))
        XCTAssertEqual(changes.values.last, .enqueued(sources))
        XCTAssertTrue(queue.insertMissingSources([runnable]), "an existing source adds no work")
        XCTAssertEqual(changes.values.last, .sources(sources))

        var newer = runnable
        newer.revision = UploadBackupRevision(rawValue: 8)
        XCTAssertTrue(queue.insertMissingSources([newer]), "the conditional insert preserves an existing source")
        XCTAssertNil(try queue.entry(for: newer.source, revision: newer.revision))
        XCTAssertEqual(changes.values.last, .sources(sources))

        XCTAssertTrue(queue.insertMissingSources([entry("settled", state: .completed)]))
        XCTAssertEqual(changes.values.last, .sources([.photoLibraryAsset: ["settled"]]))
        XCTAssertTrue(queue.insertMissingSources([runnable, entry("new", state: .discovered)]))
        XCTAssertEqual(changes.values.last, .enqueued([.photoLibraryAsset: ["a", "new"]]))
    }

    func testUnsettledRowsLeaveTerminalOutcomesOut() {
        XCTAssertTrue(
            queue.upsertBatch([
                entry("waiting", state: .discovered),
                entry("done", state: .completed),
                entry("dup", state: .alreadyBackedUp),
                entry("failed", state: .failedPermanent),
            ]))
        XCTAssertEqual(Set((try queue.decisionUnsettledRows()).map(\.source.identifier)), ["waiting", "failed"])
        XCTAssertEqual(
            try queue.decisionRows(kind: .photoLibraryAsset, identifiers: ["done"]).map(\.state), [.completed])
    }

    func testRowsForSeveralSourcesReturnEachSourceAndSkipUnknownOnes() throws {
        XCTAssertTrue(
            queue.upsertBatch([
                entry("waiting", state: .discovered),
                entry("done", state: .completed),
                entry("failed", state: .failedPermanent),
            ]))

        let rows = try queue.decisionRows(
            kind: .photoLibraryAsset, identifiers: ["waiting", "done", "unknown", "failed"])

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: rows.map { ($0.source.identifier, $0.state) }),
            ["waiting": .discovered, "done": .completed, "failed": .failedPermanent])
        XCTAssertTrue(try queue.decisionRows(kind: .photoLibraryAsset, identifiers: []).isEmpty)
        XCTAssertTrue(try queue.decisionRows(kind: .fileURL, identifiers: ["waiting"]).isEmpty)
        XCTAssertTrue(queue.isOperational())
    }

    func testEngineDropsExcludedPhotosAndRefusesWithoutAnAnswer() async throws {
        let exclusions = StubExclusions(excluded: ["excluded"])
        let engine = UploadBackupSyncEngine(
            preflight: UploadBackupPreflightIndex(store: EmptyStateStore()),
            queue: queue,
            exclusions: exclusions,
            now: { [date] in date }
        )
        _ = try await engine.enqueueBatch([candidate("kept"), candidate("excluded")])
        XCTAssertEqual(Set((try queue.decisionUnsettledRows()).map(\.source.identifier)), ["kept"])

        exclusions.available = false
        do {
            _ = try await engine.enqueueBatch([candidate("later")])
            XCTFail("an unknown exclusion state must never enqueue a photo")
        } catch {}
        XCTAssertFalse((try queue.decisionUnsettledRows()).contains { $0.source.identifier == "later" })
    }

    /// A photo whose pending row this build cannot read is queued like an included photo, so a scan never marks its
    /// revision seen without a queue row; the runner lets it wait (#982).
    func testEngineQueuesAPhotoWithAnUnreadablePendingRow() async throws {
        let exclusions = StubExclusions(excluded: ["excluded"], unreadable: ["waiting"])
        let engine = UploadBackupSyncEngine(
            preflight: UploadBackupPreflightIndex(store: EmptyStateStore()), queue: queue, exclusions: exclusions,
            now: { [date] in date })

        _ = try await engine.enqueueBatch([candidate("kept"), candidate("excluded"), candidate("waiting")])

        XCTAssertEqual(Set((try queue.decisionUnsettledRows()).map(\.source.identifier)), ["kept", "waiting"])
    }

    /// The repair paths keep a photo whose pending row this build cannot read: the missing-source sweep inserts it,
    /// and a changed photo whose row was missing is queued again (#982).
    func testRepairPathsKeepAPhotoWithAnUnreadablePendingRow() async throws {
        let exclusions = StubExclusions(excluded: ["excluded"], unreadable: ["waiting", "changed"])
        let engine = UploadBackupSyncEngine(
            preflight: UploadBackupPreflightIndex(store: EmptyStateStore()), queue: queue, exclusions: exclusions,
            now: { [date] in date })

        try await engine.enqueueMissingSources([candidate("waiting"), candidate("excluded")])
        XCTAssertEqual(Set((try queue.decisionUnsettledRows()).map(\.source.identifier)), ["waiting"])

        XCTAssertTrue(queue.upsert(entry("changed", state: .sourceMissing)))
        try await engine.enqueueChangedMissingSources([candidate("changed")])
        let changed = candidate("changed").snapshot
        XCTAssertEqual(try queue.entry(for: changed.source, revision: changed.revision)?.state, .discovered)
    }

    /// A late render reopens a backed-up photo also when its pending row cannot be read; the runner lets it wait
    /// (#982).
    func testReopeningKeepsAPhotoWithAnUnreadablePendingRow() async throws {
        let stateStore = try XCTUnwrap(
            UploadBackupStateManifestStore(url: directory.appendingPathComponent("backup-state.sqlite")))
        defer { stateStore.close() }
        let preflight = UploadBackupPreflightIndex(store: stateStore)
        let engine = UploadBackupSyncEngine(
            preflight: preflight, queue: queue, exclusions: StubExclusions(excluded: [], unreadable: ["waiting"]),
            now: { [date] in date })
        let waiting = candidate("waiting")
        try await preflight.markBackedUp(waiting.snapshot)
        XCTAssertTrue(queue.upsert(entry("waiting", state: .completed)))

        let reopened = try await engine.reopenBackedUpRevisions(
            [UploadBackupReopening(candidate: waiting, formerMain: nil)], deferringWithoutRemoteProof: false)

        XCTAssertEqual(reopened, [waiting])
        XCTAssertNil(try queue.entry(for: waiting.snapshot.source, revision: waiting.snapshot.revision))
    }

    private func candidate(_ id: String) -> UploadBackupAssetCandidate {
        UploadBackupAssetCandidate(
            snapshot: UploadBackupAssetSnapshot(
                source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id, resource: .primary),
                revision: UploadBackupRevision(rawValue: 7),
                resourceCount: 1
            ),
            originalFilename: "\(id).heic"
        )
    }
}

private final class LockedChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UploadBackupSyncQueueChange] = []
    var values: [UploadBackupSyncQueueChange] { lock.withLock { stored } }
    func append(_ change: UploadBackupSyncQueueChange) { lock.withLock { stored.append(change) } }
}

private final class StubExclusions: UploadBackupExclusionFiltering, @unchecked Sendable {
    private let lock = NSLock()
    private let excluded: Set<String>
    private let unreadable: Set<String>
    private var isAvailable = true

    init(excluded: Set<String>, unreadable: Set<String> = []) {
        self.excluded = excluded
        self.unreadable = unreadable
    }

    var available: Bool {
        get { lock.withLock { isAvailable } }
        set { lock.withLock { isAvailable = newValue } }
    }

    func exclusions(kind: UploadSourceIdentity.Kind, among identifiers: [String]) -> [String: BackupSourceExclusion]? {
        guard available else { return nil }
        var answers: [String: BackupSourceExclusion] = [:]
        for identifier in identifiers where excluded.contains(identifier) { answers[identifier] = .excluded }
        for identifier in identifiers where unreadable.contains(identifier) { answers[identifier] = .unreadable }
        return answers
    }
}

private final class EmptyStateStore: UploadBackupStateStore, @unchecked Sendable {
    func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord? { nil }
    func hasAnyRecord(for source: UploadSourceIdentity) -> Bool { false }
    func upsert(_ record: UploadBackupAssetRecord) -> Bool { true }
    func count() -> Int { 0 }
}

extension PendingBackupStoreTests {
    private func restored829State() throws -> PendingSourceState {
        let excluded = try XCTUnwrap(
            store.exclude(
                [PendingExclusionRequest(key: key, presentation: presentation(), remote: remote)], at: date)?.first)
        XCTAssertTrue(
            store.completeEffect(
                .remoteTrash, for: key, generation: excluded.generation,
                remoteLinkID: remote.nodeID, at: date))
        return try XCTUnwrap(store.includeRestoredInProton([key], confirmedRemotes: [remote], at: date)?.first)
    }

    func testRestoreWaitingKeepsUIDAttemptsAndExactDueTimeAcrossSQLiteReopen() throws {
        let checked = try restored829State()
        let due = date.addingTimeInterval(120)
        XCTAssertTrue(store.finishRestoreRecheck(checked, outcome: .waiting(until: due), at: date))
        let before = try XCTUnwrap(store.sourceState(for: key))
        XCTAssertEqual(before.remote, remote)
        XCTAssertTrue(before.needsQueueSync)
        XCTAssertEqual(before.attempts, checked.attempts)
        XCTAssertEqual(before.nextAttemptAt, due)
        store.close()
        store = try XCTUnwrap(PendingBackupManifestStore(url: storeURL))
        XCTAssertEqual(store.sourceState(for: key), before, "The obligation is durable, not controller memory")
        XCTAssertTrue(store.finishRestoreRecheck(before, outcome: .waiting(until: date), at: date))
        XCTAssertEqual(
            store.sourceState(for: key)?.nextAttemptAt, date.addingTimeInterval(1),
            "An expired deferral must not create a same-time busy loop")
    }

    func testRestoreCleanupRejectsEachChangedBindingIndependently() throws {
        for column in [
            "generation=generation+1", "remote_link_id='newer-link'", "desired='excluded'", "needs_queue_sync=0",
        ] {
            let localURL = directory.appendingPathComponent(UUID().uuidString + ".sqlite")
            let local = try XCTUnwrap(PendingBackupManifestStore(url: localURL))
            defer { local.close() }
            let checked = try XCTUnwrap(
                local.exclude(
                    [PendingExclusionRequest(key: key, presentation: nil, remote: remote)], at: date)?.first)
            XCTAssertEqual(local.beginRemoteOperation(.remoteTrash, for: [checked]), [key])
            let included = try XCTUnwrap(
                local.includeRestoredInProton([key], confirmedRemotes: [remote], at: date)?.first)
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(localURL.path, &db), SQLITE_OK)
            let handle = try XCTUnwrap(db)
            defer { sqlite3_close(handle) }
            XCTAssertEqual(sqlite3_exec(handle, "UPDATE source_state SET \(column);", nil, nil, nil), SQLITE_OK)
            let changed = try XCTUnwrap(local.sourceState(for: key))
            XCTAssertTrue(local.finishRestoreRecheck(included, outcome: .completed, at: date.addingTimeInterval(1)))
            XCTAssertEqual(local.sourceState(for: key), changed, "A stale result must preserve \(column)")
            XCTAssertEqual(local.sourceState(for: key)?.remoteOperation, .remoteTrash)
        }
    }
}

extension PendingBackupStoreTests {
    func testRestoreCompletionCannotRetireAnOwedRemoteCompensation() throws {
        for owed in ["needs_remote_restore", "needs_remote_trash"] {
            let url = directory.appendingPathComponent(UUID().uuidString + ".sqlite")
            let local = try XCTUnwrap(PendingBackupManifestStore(url: url))
            defer { local.close() }
            XCTAssertNotNil(
                local.exclude([PendingExclusionRequest(key: key, presentation: nil, remote: remote)], at: date))
            let checked = try XCTUnwrap(
                local.includeRestoredInProton([key], confirmedRemotes: [remote], at: date)?.first)
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
            let handle = try XCTUnwrap(db)
            defer { sqlite3_close(handle) }
            XCTAssertEqual(sqlite3_exec(handle, "UPDATE source_state SET \(owed)=1;", nil, nil, nil), SQLITE_OK)
            XCTAssertTrue(local.finishRestoreRecheck(checked, outcome: .completed, at: date))
            let kept = try XCTUnwrap(local.sourceState(for: key), "Completion cannot delete an owed remote action")
            XCTAssertEqual(kept.remote, remote)
            XCTAssertTrue(owed == "needs_remote_restore" ? kept.needsRemoteRestore : kept.needsRemoteTrash)
        }
    }
}

extension PendingBackupStoreTests {
    func testStandalonePendingWritesRefuseAnOpenTransaction() throws {
        try checkStandaloneWrites(under: .openTransaction)
    }

    func testStandalonePendingWritesRefuseALastingFailure() throws {
        try checkStandaloneWrites(under: .lastingFailure)
    }

    func testStandalonePendingWritesRefuseAFailedRollback() throws {
        try checkStandaloneWrites(under: .failedRollback)
    }

    func testStandalonePendingWritesCommitWhenHealthy() throws {
        try checkStandaloneWrites(under: nil)
    }

    private func checkStandaloneWrites(under fault: PendingStoreTransactionFault?) throws {
        let keepKey = PendingSourceKey(kind: .photoLibraryAsset, identifier: "kept")
        let writers: [(String, () throws -> Bool)] = [
            (
                "upload evidence",
                {
                    self.store.recordUploadEvidence(
                        self.key, revision: UploadBackupRevision(rawValue: 2), at: self.date)
                }
            ),
            ("handoff pruning", { self.store.pruneAcknowledgedHandoffs(olderThan: self.date) }),
            ("effect retry", { self.store.deferEffects(for: self.key, at: self.date.addingTimeInterval(100)) }),
            (
                "keep remote",
                {
                    self.store.keepRemote(
                        self.remote, of: keepKey, generation: 1, revision: nil, at: self.date) != nil
                }
            ),
            (
                "earlier upload trash",
                {
                    self.store.trashEarlierUpload(self.remote, of: self.key, generation: 1, at: self.date) != nil
                }
            ),
            ("favorite intent", { self.store.setFavoriteIntent(self.key, favorite: false, at: self.date) }),
            ("album intent", { self.store.addAlbumIntent(self.key, albumID: "album", at: self.date) }),
            (
                "action retry",
                {
                    self.store.retryAction(try XCTUnwrap(self.store.actions().first), at: self.date)
                }
            ),
            ("action failure", { self.store.failAction(try XCTUnwrap(self.store.actions().first)) }),
            ("action completion", { self.store.completeAction(try XCTUnwrap(self.store.actions().first)) }),
            (
                "saved photo",
                {
                    self.store.recordSavedFromApp(localIdentifier: "saved", remote: self.remote, at: self.date)
                }
            ),
        ]
        let originalStore = store
        let originalDirectory = try XCTUnwrap(directory)
        defer {
            store.close()
            store = originalStore
            directory = originalDirectory
        }
        for (name, write) in writers {
            store.close()
            directory = originalDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            store = try XCTUnwrap(PendingBackupManifestStore(url: storeURL))
            XCTAssertTrue(store.recordUploadEvidence(key, revision: UploadBackupRevision(rawValue: 1), at: date))
            XCTAssertNotNil(
                store.exclude([PendingExclusionRequest(key: key, presentation: presentation(), remote: nil)], at: date))
            XCTAssertNotNil(
                store.exclude([PendingExclusionRequest(key: keepKey, presentation: nil, remote: remote)], at: date))
            XCTAssertTrue(store.setFavoriteIntent(key, favorite: true, at: date))
            let oldKey = PendingSourceKey(kind: .photoLibraryAsset, identifier: "prunable")
            let oldRevision = UploadBackupRevision(rawValue: 1)
            XCTAssertEqual(
                store.recordHandoff(
                    PendingHandoff(
                        key: oldKey, revision: oldRevision, remote: remote, kind: .uploaded,
                        createdAt: date.addingTimeInterval(-100))), .recorded)
            XCTAssertTrue(store.acknowledgeHandoffs([(oldKey, oldRevision)]))
            let before = try pendingTables()
            if let fault {
                let connection = try fault.install(on: store, key: key)
                XCTAssertFalse(try write(), "\(fault): \(name) must report refusal")

                // Commit through the fixture connection: false must not hide a write in the open transaction.
                connection.withLock {
                    if sqlite3_get_autocommit(connection.database) == 0 {
                        XCTAssertEqual(sqlite3_exec(connection.database, "COMMIT;", nil, nil, nil), SQLITE_OK)
                    }
                }
                XCTAssertEqual(try pendingTables(), before, "\(fault): \(name) must preserve every durable row")
            } else {
                XCTAssertTrue(try write(), "\(name) must still succeed while healthy")
                XCTAssertNotEqual(try pendingTables(), before, "the healthy \(name) fixture must change a row")
            }
        }
    }
}
