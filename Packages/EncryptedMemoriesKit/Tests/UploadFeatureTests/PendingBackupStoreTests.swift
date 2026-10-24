import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

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
        XCTAssertFalse(store.isOperational(), "an unknown non-null enum must record a decode failure")
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
        try withRawPendingDatabase {
            XCTAssertEqual(sqlite3_exec($0, "UPDATE pending_action SET kind='invalid';", nil, nil, nil), SQLITE_OK)
        }
        _ = store.actions()
        XCTAssertFalse(store.isOperational())
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(
                    key: key, revision: UploadBackupRevision(rawValue: 7), remote: remote,
                    kind: .uploaded, createdAt: date)), .excludedRemoteNeedsTrash)
        let included = try XCTUnwrap(try XCTUnwrap(store.include([key], at: date)).first)
        XCTAssertTrue(store.deferEffects(for: key, at: date))
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
            XCTAssertFalse(store.isOperational(), "a real read failure must record failed health")
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

    private func withOneDeniedSourceSelect(_ body: () throws -> Void) throws {
        let connection = try XCTUnwrap(
            Mirror(reflecting: store!).children.first(where: { $0.label == "connection" })?.value
                as? SQLiteStoreConnection)
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
        XCTAssertEqual(store.excludedIdentifiers(kind: .photoLibraryAsset, among: ["asset-1", "other"]), ["asset-1"])

        let included = try XCTUnwrap(store.include([key], at: date)).first
        XCTAssertEqual(included?.desired, .included)
        XCTAssertEqual(included?.generation, 2)

        // A late completion of the delete's queue sync must not clear the restore's request.
        XCTAssertTrue(store.completeEffect(.queueSync, for: key, generation: 1, at: date))
        XCTAssertEqual(store.sourceState(for: key)?.needsQueueSync, true)

        XCTAssertTrue(store.completeEffect(.queueSync, for: key, generation: 2, at: date))
        XCTAssertNil(store.sourceState(for: key), "an included source without due effects leaves the store")
        XCTAssertEqual(store.excludedIdentifiers(kind: .photoLibraryAsset, among: ["asset-1"]), [])
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
        XCTAssertTrue(store.removeEvidence(for: []))
        XCTAssertTrue(store.removeEvidence([(PendingSourceKey, UploadBackupRevision)]()))
        XCTAssertTrue(store.acknowledgeHandoffs([]))
        XCTAssertTrue(store.unlistFromTrash([], at: date))
        XCTAssertEqual(store.excludedIdentifiers(kind: .photoLibraryAsset, among: []), [])
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

    func testPendingActionDecodeFailureStaysStickyWithoutChangingLaterSQLResults() throws {
        XCTAssertTrue(store.setFavoriteIntent(key, favorite: true, at: date))
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(storeURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, "UPDATE pending_action SET kind='invalid-kind';", nil, nil, nil), SQLITE_OK)
        _ = store.actions()
        XCTAssertFalse(store.isOperational())
        let revision = UploadBackupRevision(rawValue: 10)
        XCTAssertTrue(store.recordUploadEvidence(key, revision: revision, at: date))
        XCTAssertEqual(store.evidenceRevisions(), [key: [revision]])
        XCTAssertFalse(store.isOperational(), "successful SQL cannot clear recorded failure")
        XCTAssertNil(store.excludedIdentifiers(kind: .photoLibraryAsset, among: [key.identifier]))
    }

    func testClosedStoreCannotConfirmExclusions() {
        store.close()
        XCTAssertNil(store.excludedIdentifiers(kind: .photoLibraryAsset, among: ["asset-1"]))
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
        XCTAssertEqual(queue.entry(for: runnable.source, revision: runnable.revision)?.state, .completed)
        XCTAssertEqual(changes.values, [.enqueued(sources), .sources(sources), .sources(sources), .sources(sources)])

        let failed = entry("b", state: .failed)
        XCTAssertTrue(queue.upsert(failed))
        XCTAssertTrue(queue.upsertBatch([entry("b", state: .discovered)]))
        XCTAssertEqual(changes.values.last, .enqueued([.photoLibraryAsset: ["b"]]))

        XCTAssertTrue(queue.upsert(entry("active", state: .uploading)))
        XCTAssertTrue(queue.upsert(entry("active", state: .needsRemoteReconciliation)))
        XCTAssertEqual(changes.values.last, .sources([.photoLibraryAsset: ["active"]]))
        XCTAssertEqual(
            queue.entry(for: entry("active", state: .uploading).source, revision: runnable.revision)?.state, .uploading)

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
        XCTAssertNil(queue.entry(for: newer.source, revision: newer.revision))
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
        XCTAssertEqual(Set(queue.unsettledRows().map(\.source.identifier)), ["waiting", "failed"])
        XCTAssertEqual(queue.rows(kind: .photoLibraryAsset, identifiers: ["done"]).map(\.state), [.completed])
    }

    func testRowsForSeveralSourcesReturnEachSourceAndSkipUnknownOnes() {
        XCTAssertTrue(
            queue.upsertBatch([
                entry("waiting", state: .discovered),
                entry("done", state: .completed),
                entry("failed", state: .failedPermanent),
            ]))

        let rows = queue.rows(kind: .photoLibraryAsset, identifiers: ["waiting", "done", "unknown", "failed"])

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: rows.map { ($0.source.identifier, $0.state) }),
            ["waiting": .discovered, "done": .completed, "failed": .failedPermanent])
        XCTAssertTrue(queue.rows(kind: .photoLibraryAsset, identifiers: []).isEmpty)
        XCTAssertTrue(queue.rows(kind: .fileURL, identifiers: ["waiting"]).isEmpty)
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
        XCTAssertEqual(Set(queue.unsettledRows().map(\.source.identifier)), ["kept"])

        exclusions.available = false
        do {
            _ = try await engine.enqueueBatch([candidate("later")])
            XCTFail("an unknown exclusion state must never enqueue a photo")
        } catch {}
        XCTAssertFalse(queue.unsettledRows().contains { $0.source.identifier == "later" })
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
    private var isAvailable = true

    init(excluded: Set<String>) {
        self.excluded = excluded
    }

    var available: Bool {
        get { lock.withLock { isAvailable } }
        set { lock.withLock { isAvailable = newValue } }
    }

    func excludedIdentifiers(kind: UploadSourceIdentity.Kind, among identifiers: [String]) -> Set<String>? {
        guard available else { return nil }
        return excluded.intersection(identifiers)
    }
}

private final class EmptyStateStore: UploadBackupStateStore, @unchecked Sendable {
    func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord? { nil }
    func hasAnyRecord(for source: UploadSourceIdentity) -> Bool { false }
    func upsert(_ record: UploadBackupAssetRecord) -> Bool { true }
    func count() -> Int { 0 }
}
