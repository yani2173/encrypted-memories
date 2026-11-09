import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

/// Exercises the production coordinator and SQLite store. Only remote effects and metadata are test adapters.
final class PendingBackupActionIsolationTests: XCTestCase {
    func testHealthySourcesWithoutPendingStatePersistEveryActionResult() async throws {
        for result in [PendingEffectResult.done, .retry, .permanentFailure] {
            try await exercise(damage: .none, result: result)
        }
    }

    func testUnreadableActionDoesNotBlockHealthyFavoriteAndAlbumResults() async throws {
        for result in [PendingEffectResult.done, .retry, .permanentFailure] {
            try await exercise(damage: .action, result: result)
        }
    }

    func testUnreadableSourceDoesNotBlockHealthyFavoriteAndAlbumResults() async throws {
        for result in [PendingEffectResult.done, .retry, .permanentFailure] {
            try await exercise(damage: .sourceState, result: result)
        }
    }

    func testAnUncachedExcludedOrUnreadableStateDoesNotAuthorizeAnAction() async throws {
        for desired in ["excluded", "future-state"] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pending-action-keyed-\(UUID().uuidString)", isDirectory: true)
            let url = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
            let store = try XCTUnwrap(PendingBackupManifestStore(url: url))
            defer {
                store.close()
                try? FileManager.default.removeItem(at: directory)
            }
            let date = Date(timeIntervalSince1970: 1_750_000_000.75)
            let bad = key("blocked")
            let target = key("new-state")
            _ = try XCTUnwrap(store.exclude([.init(key: bad, presentation: nil, remote: nil)], at: date))
            try change(
                "UPDATE source_state SET desired='future-state', needs_queue_sync=0 WHERE source_id='blocked';", at: url
            )
            let effects = IsolationEffects(result: .done)
            let coordinator = PendingBackupCoordinator(
                store: store, queues: [:], metadataProvider: IsolationMetadata(), effects: effects, recorder: nil,
                configuration: .init(membershipInterval: .zero), now: { date },
                sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
            await coordinator.start()
            XCTAssertNotEqual(
                store.recordHandoff(
                    .init(
                        key: target, revision: .init(rawValue: 9), remote: remote(target), kind: .uploaded,
                        createdAt: date, acknowledged: true)), .failed)
            // This state appears after the inventory read, so only the fresh keyed read can reject it.
            _ = try XCTUnwrap(store.exclude([.init(key: target, presentation: nil, remote: nil)], at: date))
            try change(
                "UPDATE source_state SET desired='\(desired)', needs_queue_sync=0 WHERE source_id='new-state';", at: url
            )
            let preserved = try storedRows(for: "new-state", at: url)
            let accepted = await coordinator.setFavorite([target.localUID], favorite: true)
            await coordinator.close()
            XCTAssertTrue(accepted)
            let events = await effects.events
            XCTAssertTrue(events.isEmpty, "A keyed \(desired) state must not authorize any remote action")
            let action = try XCTUnwrap(store.actionsRead().actions.first { $0.key == target })
            XCTAssertFalse(action.failed)
            XCTAssertEqual(action.attempts, 0)
            XCTAssertEqual(action.nextAttemptAt, date)
            let after = try storedRows(for: "new-state", at: url)
            XCTAssertEqual(after[0], preserved[0], "Eligibility must not change the pending source")
            XCTAssertEqual(after[2], preserved[2], "Eligibility must not change the handoff")
        }
    }

    private enum Damage { case none, action, sourceState }

    private func exercise(damage: Damage, result: PendingEffectResult) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-action-isolation-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        let store = try XCTUnwrap(PendingBackupManifestStore(url: url))
        defer {
            store.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let date = Date(timeIntervalSince1970: 1_750_000_000.75)
        let bad = key("blocked")
        let favorite = key("healthy-favorite")
        let album = key("healthy-album")
        // Handoffs exist before startup. No recorder event or fabricated coordinator state authorizes an action.
        for sourceKey in [bad, favorite, album] {
            XCTAssertNotEqual(
                store.recordHandoff(
                    PendingHandoff(
                        key: sourceKey, revision: UploadBackupRevision(rawValue: 9),
                        remote: remote(sourceKey), kind: .uploaded, createdAt: date, acknowledged: true)),
                .failed)
        }
        XCTAssertTrue(store.setFavoriteIntent(bad, favorite: false, at: date))
        _ = try XCTUnwrap(
            store.exclude(
                [PendingExclusionRequest(key: bad, presentation: nil, remote: remote(bad))], at: date))
        // Every case has identical duties. Only one enum field differs from the healthy control.
        try change(
            "UPDATE source_state SET needs_queue_sync=0, needs_remote_trash=0 WHERE source_id='blocked';",
            at: url)
        if damage == .sourceState {
            try change("UPDATE source_state SET desired='future-state' WHERE source_id='blocked';", at: url)
        } else if damage == .action {
            try change("UPDATE pending_action SET kind='future-action' WHERE source_id='blocked';", at: url)
        }
        let preserved = try storedRows(for: "blocked", at: url)
        let beforeActions = store.actionsRead()
        XCTAssertEqual(beforeActions.complete, damage != .action)
        XCTAssertEqual(beforeActions.actions.map(\.key), damage == .action ? [] : [bad])
        XCTAssertEqual(store.sourceStatesRead().complete, damage != .sourceState)
        XCTAssertTrue(store.dueSourceStatesRead(by: date).complete, "No due-source read fails in this reproducer")
        XCTAssertEqual(store.dueActionsRead(by: date).complete, damage != .action)
        XCTAssertEqual(store.sourceStateRead(for: bad) == .unreadable, damage == .sourceState)
        XCTAssertTrue(store.isOperational(), "One undecodable row must not make the connection unavailable")
        for sourceKey in [favorite, album] {
            XCTAssertEqual(store.sourceStateRead(for: sourceKey), .readable(nil))
            XCTAssertEqual(store.latestHandoffsRead(for: [sourceKey])[sourceKey]?.handoff?.remote, remote(sourceKey))
        }
        let effects = IsolationEffects(result: result)
        let coordinator = PendingBackupCoordinator(
            store: store, queues: [:], metadataProvider: IsolationMetadata(), effects: effects, recorder: nil,
            configuration: .init(membershipInterval: .zero), now: { date },
            // Timers remain cancellable and cannot race the foreground dispatch or advance a persisted retry.
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let failuresBefore = PhotoDiagnostics.shared.counter("pending.actionFailed")
        await coordinator.start()
        let favoriteAccepted = await coordinator.setFavorite([favorite.localUID], favorite: true)
        let albumAccepted = await coordinator.addToAlbum([album.localUID], albumID: "target-album")
        // Close cancels all owned coordinator timers before reading stable effects and durable results.
        await coordinator.close()
        XCTAssertTrue(favoriteAccepted)
        XCTAssertTrue(albumAccepted)
        let events = await effects.events
        XCTAssertEqual(
            events, [.volume, .favorite(remote(favorite), true), .volume, .album(remote(album), "target-album")],
            "Fully readable healthy favorite and album actions must dispatch exactly once (\(result))")
        XCTAssertEqual(
            PhotoDiagnostics.shared.counter("pending.actionFailed") - failuresBefore,
            result == .permanentFailure ? 2 : 0, "Only terminal results increment the failure diagnostic")
        let after = store.actionsRead()
        XCTAssertEqual(after.complete, damage != .action)
        for (sourceKey, kind) in [(favorite, PendingActionKind.favorite), (album, .addToAlbum)] {
            XCTAssertEqual(store.sourceStateRead(for: sourceKey), .readable(nil), "No pending state is synthesized")
            let actions = after.actions.filter { $0.key == sourceKey }
            if result == .done {
                XCTAssertTrue(actions.isEmpty, "A successful \(kind) must be durably completed")
            } else {
                let action = try XCTUnwrap(actions.first)
                XCTAssertEqual(actions.count, 1)
                XCTAssertEqual(action.kind, kind)
                XCTAssertEqual(action.albumID, kind == .favorite ? "" : "target-album")
                XCTAssertTrue(action.desired)
                XCTAssertEqual(action.createdAt, date)
                XCTAssertEqual(action.failed, result == .permanentFailure)
                XCTAssertEqual(action.attempts, result == .retry ? 1 : 0)
                XCTAssertEqual(action.nextAttemptAt, result == .retry ? date.addingTimeInterval(60) : date)
            }
        }
        XCTAssertEqual(
            try storedRows(for: "blocked", at: url), preserved,
            "Every column of the blocked source, action and handoff must remain unchanged")
        XCTAssertEqual(store.sourceStateRead(for: bad) == .unreadable, damage == .sourceState)
        XCTAssertEqual(store.sourceStatesRead().complete, damage != .sourceState)
        XCTAssertTrue(store.isOperational())
    }

    private func key(_ id: String) -> PendingSourceKey {
        PendingSourceKey(kind: .photoLibraryAsset, identifier: id)
    }

    private func remote(_ key: PendingSourceKey) -> PhotoUID {
        PhotoUID(volumeID: "test-volume", nodeID: "remote-" + key.identifier)
    }

    private func change(_ sql: String, at url: URL) throws {
        try withDatabase(at: url, flags: SQLITE_OPEN_READWRITE) { db in
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_changes(db), 1, "Only the named entry changes")
        }
    }

    private struct Cell: Equatable {
        let type: Int32
        let bytes: Data
    }

    /// Compare all stored columns, including unknown enum bytes, attempts, dates, generation and handoff flags.
    private func storedRows(for identifier: String, at url: URL) throws -> [[[Cell]]] {
        try withDatabase(at: url, flags: SQLITE_OPEN_READONLY) { db in
            try ["source_state", "pending_action", "handoff"].map { table in
                var statement: OpaquePointer?
                XCTAssertEqual(
                    sqlite3_prepare_v2(
                        db, "SELECT * FROM \(table) WHERE source_id=? ORDER BY rowid;", -1,
                        &statement, nil), SQLITE_OK)
                let stmt = try XCTUnwrap(statement)
                defer { sqlite3_finalize(stmt) }
                _ = identifier.withCString {
                    sqlite3_bind_text(stmt, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                var rows: [[Cell]] = []
                var step = sqlite3_step(stmt)
                while step == SQLITE_ROW {
                    rows.append(
                        (0..<sqlite3_column_count(stmt)).map { column in
                            let type = sqlite3_column_type(stmt, column)
                            let bytes = sqlite3_column_blob(stmt, column)
                            return Cell(
                                type: type,
                                bytes: bytes.map {
                                    Data(bytes: $0, count: Int(sqlite3_column_bytes(stmt, column)))
                                } ?? Data())
                        })
                    step = sqlite3_step(stmt)
                }
                XCTAssertEqual(step, SQLITE_DONE)
                return rows
            }
        }
    }

    private func withDatabase<T>(at url: URL, flags: Int32, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, flags, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        return try body(db)
    }
}

private struct IsolationMetadata: PendingSourceMetadataProviding {
    func metadata(for keys: [PendingSourceKey]) async -> [PendingSourceKey: PendingPresentationMetadata] { [:] }
}

private actor IsolationEffects: PendingBackupEffects {
    enum Event: Equatable {
        case volume
        case favorite(PhotoUID, Bool)
        case album(PhotoUID, String)
        case remove([String])
        case returned([PendingSourceKey])
        case trash([PhotoUID])
        case restore([PhotoUID])
    }

    private let result: PendingEffectResult
    private(set) var events: [Event] = []

    init(result: PendingEffectResult) { self.result = result }

    func photosVolumeID() async -> String? {
        events.append(.volume)
        return "test-volume"
    }
    func removeFromBackup(kind: UploadSourceIdentity.Kind, identifiers: [String]) async -> Bool {
        events.append(.remove(identifiers))
        return true
    }
    func returnToBackup(_ keys: [PendingSourceKey]) async -> Set<PendingSourceKey> {
        events.append(.returned(keys))
        return Set(keys)
    }
    func returnToBackup(_ states: [PendingSourceState]) async -> [PendingSourceKey: PendingBackupReturnOutcome] {
        events.append(.returned(states.map(\.key)))
        return Dictionary(uniqueKeysWithValues: states.map { ($0.key, .completed) })
    }
    func trashRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
        events.append(.trash(uids))
        return .done
    }
    func restoreRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
        events.append(.restore(uids))
        return .done
    }
    func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult {
        events.append(.favorite(uid, favorite))
        return result
    }
    func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult {
        events.append(.album(uid, albumID))
        return result
    }
}
