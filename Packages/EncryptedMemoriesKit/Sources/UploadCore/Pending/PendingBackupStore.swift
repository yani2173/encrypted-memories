import Foundation
import PhotosCore
import SQLite3

/// Device-local state for pending grid tiles (`pending-backup-v1.sqlite`): desired backup state per source,
/// duplicate-check evidence, handoffs to Proton photos, deferred actions and photos the app saved itself.
///
/// It is a separate store because every existing store uses an exact-schema gate without migrations, and
/// the backup queue must never become unreadable. Writes are synchronous so the backup runner can record a
/// handoff before it clears a commit receipt. An unavailable store fails closed: no pending tile shows,
/// and the backup engine enqueues no new photos, because it cannot prove that they were not deleted.
public final class PendingBackupManifestStore: @unchecked Sendable {
    public static let databaseFileName = "pending-backup-v1.sqlite"

    private static let schemaVersion = 1
    private let connection: SQLiteStoreConnection
    private var db: OpaquePointer? { connection.database }

    public init?(url: URL, policy: LibraryDatabasePolicy = .conservative) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let handle = Self.openOnce(url: url, policy: policy) else { return nil }
        connection = SQLiteStoreConnection(database: handle)
    }

    deinit { close() }

    public func close() { connection.close() }

    public func isOperational() -> Bool { connection.isOperational(probeDatabase: false) }

    // MARK: - Duplicate-check evidence

    /// The runner decided after the duplicate check that this revision needs an upload.
    @discardableResult
    public func recordUploadEvidence(_ key: PendingSourceKey, revision: UploadBackupRevision, at date: Date) -> Bool {
        connection.withLock {
            execute(
                """
                INSERT INTO upload_evidence(source_kind, source_id, revision_us, recorded_at)
                VALUES(?, ?, ?, ?)
                ON CONFLICT(source_kind, source_id, revision_us) DO NOTHING;
                """
            ) { stmt in
                bindKey(stmt, key)
                sqlite3_bind_int64(stmt, 3, revision.rawValue)
                sqlite3_bind_double(stmt, 4, date.timeIntervalSince1970)
            }
        }
    }

    public func evidenceRevisions() -> [PendingSourceKey: Set<UploadBackupRevision>] {
        connection.withLock {
            var result: [PendingSourceKey: Set<UploadBackupRevision>] = [:]
            _ = query("SELECT source_kind, source_id, revision_us FROM upload_evidence;") { stmt in
                guard let key = key(stmt, kindColumn: 0, idColumn: 1) else { return }
                result[key, default: []].insert(UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 2)))
            }
            return result
        }
    }

    /// Removes evidence of sources that settled or left the backup set.
    @discardableResult
    public func removeEvidence(for keys: [PendingSourceKey]) -> Bool {
        guard !keys.isEmpty else { return true }
        return connection.withLock {
            transaction {
                keys.allSatisfy { key in
                    execute("DELETE FROM upload_evidence WHERE source_kind=? AND source_id=?;") { bindKey($0, key) }
                }
            }
        }
    }

    /// Removes the evidence of exactly these revisions, so a newer revision keeps its own evidence.
    @discardableResult
    public func removeEvidence(_ revisions: [(PendingSourceKey, UploadBackupRevision)]) -> Bool {
        guard !revisions.isEmpty else { return true }
        return connection.withLock {
            transaction {
                revisions.allSatisfy { key, revision in
                    execute("DELETE FROM upload_evidence WHERE source_kind=? AND source_id=? AND revision_us=?;") {
                        stmt in
                        bindKey(stmt, key)
                        sqlite3_bind_int64(stmt, 3, revision.rawValue)
                    }
                }
            }
        }
    }

    // MARK: - Handoffs

    /// Records that a revision has a Proton photo. When the person excluded the source while it uploaded,
    /// the same transaction schedules that photo for the Proton trash.
    public func recordHandoff(_ handoff: PendingHandoff) -> PendingHandoffOutcome {
        connection.withLock {
            var outcome = PendingHandoffOutcome.recorded
            let committed = transaction {
                guard
                    execute(
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
                          kind=excluded.kind,
                          created_at=CASE
                            WHEN handoff.remote_volume_id=excluded.remote_volume_id
                             AND handoff.remote_link_id=excluded.remote_link_id
                             AND handoff.kind='uploaded' AND excluded.kind='uploaded' THEN handoff.created_at
                            ELSE excluded.created_at
                          END;
                        """,
                        bind: { stmt in
                            bindKey(stmt, handoff.key)
                            sqlite3_bind_int64(stmt, 3, handoff.revision.rawValue)
                            bindText(stmt, 4, handoff.remote.volumeID)
                            bindText(stmt, 5, handoff.remote.nodeID)
                            bindText(stmt, 6, handoff.kind.rawValue)
                            sqlite3_bind_double(stmt, 7, handoff.createdAt.timeIntervalSince1970)
                        })
                else { return false }
                guard case .readable(let current) = sourceStateLocked(handoff.key) else { return false }
                guard let state = current, state.desired == .excluded else { return true }
                outcome = .excludedRemoteNeedsTrash
                // The delete of an unfinished edit still owes the trash of the earlier upload. That photo stays the
                // state's photo; its completed trash moves on to this handoff, see `completeEffect`.
                if state.needsRemoteTrash, let pending = state.remote, pending.nodeID != handoff.remote.nodeID {
                    return true
                }
                return execute(
                    """
                    UPDATE source_state
                    SET needs_remote_trash=1, needs_remote_restore=0, remote_volume_id=?, remote_link_id=?,
                        next_attempt_at=?, updated_at=?
                    WHERE source_kind=? AND source_id=?;
                    """
                ) { stmt in
                    bindText(stmt, 1, handoff.remote.volumeID)
                    bindText(stmt, 2, handoff.remote.nodeID)
                    sqlite3_bind_double(stmt, 3, handoff.createdAt.timeIntervalSince1970)
                    sqlite3_bind_double(stmt, 4, handoff.createdAt.timeIntervalSince1970)
                    bindText(stmt, 5, handoff.key.kind.rawValue)
                    bindText(stmt, 6, handoff.key.identifier)
                }
            }
            return committed ? outcome : .failed
        }
    }

    public func unacknowledgedHandoffs() -> [PendingHandoff] {
        connection.withLock { handoffsLocked(where: "acknowledged=0") }
    }

    /// When the handoff of a revision became the current one. A repeated record of the same upload, for example
    /// the replay of its receipt, keeps the first time.
    public func handoffTime(for key: PendingSourceKey, revision: UploadBackupRevision) -> Date? {
        connection.withLock {
            handoffsLocked(where: "source_kind=? AND source_id=? AND revision_us=?") { stmt in
                self.bindKey(stmt, key)
                sqlite3_bind_int64(stmt, 3, revision.rawValue)
            }.first?.createdAt
        }
    }

    /// The handoff recorded last for each source, acknowledged or not. Undoing an edit can return a photo to an
    /// earlier revision, so the revision does not tell which handoff is the current one.
    /// nil for an absent and for an unreadable handoff. Use `latestHandoffsRead(for:)` to tell them apart.
    public func latestHandoffs(for keys: [PendingSourceKey]) -> [PendingSourceKey: PendingHandoff] {
        latestHandoffsRead(for: keys).compactMapValues(\.handoff)
    }

    /// The latest handoff of each source, or `unreadable` when its query failed or its row did not decode. Unlike the
    /// list readers, this read leaves the store's failure state unchanged, as before.
    public func latestHandoffsRead(for keys: [PendingSourceKey]) -> [PendingSourceKey: PendingHandoffRead] {
        guard !keys.isEmpty else { return [:] }
        return connection.withLock {
            var result: [PendingSourceKey: PendingHandoffRead] = [:]
            for key in keys {
                result[key] = latestHandoffLocked(key)
            }
            return result
        }
    }

    private func latestHandoffLocked(_ key: PendingSourceKey) -> PendingHandoffRead {
        var stmt: OpaquePointer?
        guard
            prepare(
                """
                SELECT source_kind, source_id, revision_us, remote_volume_id, remote_link_id, kind,
                       created_at, acknowledged
                FROM handoff WHERE source_kind=? AND source_id=?
                ORDER BY created_at DESC, revision_us DESC LIMIT 1;
                """, &stmt)
        else { return .unreadable }
        defer { sqlite3_finalize(stmt) }
        bindKey(stmt, key)
        switch sqlite3_step(stmt) {
        case SQLITE_ROW:
            guard let handoff = handoffRow(stmt) else { return .unreadable }
            return .readable(handoff)
        case SQLITE_DONE: return .readable(nil)
        default: return .unreadable
        }
    }

    /// The handoff whose Proton photo is `remote`, for a restore from the Proton trash.
    public func handoffs(forRemoteLinkIDs linkIDs: [String]) -> [PendingHandoff] {
        guard !linkIDs.isEmpty else { return [] }
        return connection.withLock {
            var result: [PendingHandoff] = []
            for linkID in linkIDs {
                result += handoffsLocked(where: "remote_link_id=?") { self.bindText($0, 1, linkID) }
            }
            return result
        }
    }

    @discardableResult
    public func acknowledgeHandoffs(_ handoffs: [(PendingSourceKey, UploadBackupRevision)]) -> Bool {
        guard !handoffs.isEmpty else { return true }
        return connection.withLock {
            transaction {
                handoffs.allSatisfy { key, revision in
                    execute(
                        "UPDATE handoff SET acknowledged=1 WHERE source_kind=? AND source_id=? AND revision_us=?;"
                    ) { stmt in
                        bindKey(stmt, key)
                        sqlite3_bind_int64(stmt, 3, revision.rawValue)
                    }
                }
            }
        }
    }

    /// Acknowledged handoffs are only needed to map a restored Proton photo back to its source.
    @discardableResult
    public func pruneAcknowledgedHandoffs(olderThan cutoff: Date) -> Bool {
        connection.withLock {
            // An unfinished action still needs its source's Proton photo, and so does an unfinished trash.
            execute(
                """
                DELETE FROM handoff
                WHERE acknowledged=1 AND created_at < ?
                  AND NOT EXISTS (
                    SELECT 1 FROM pending_action a
                    WHERE a.source_kind=handoff.source_kind AND a.source_id=handoff.source_id AND a.failed=0
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM source_state s
                    WHERE s.source_kind=handoff.source_kind AND s.source_id=handoff.source_id
                      AND s.needs_remote_trash=1
                  );
                """
            ) { sqlite3_bind_double($0, 1, cutoff.timeIntervalSince1970) }
        }
    }

    // MARK: - Desired state

    /// The rows that decode. Use `sourceStatesRead()` where a missing row must not count as "nothing owed".
    public func sourceStates() -> [PendingSourceState] {
        sourceStatesRead().states
    }

    /// Every row that decodes, and whether the query succeeded and every row decoded.
    public func sourceStatesRead() -> PendingSourceStatesRead {
        connection.withLock {
            let read = sourceStatesLocked(where: nil)
            return PendingSourceStatesRead(states: read.states, complete: read.succeeded)
        }
    }

    /// nil for an absent and for an unreadable row. Use `sourceStateRead(for:)` to tell them apart.
    public func sourceState(for key: PendingSourceKey) -> PendingSourceState? {
        sourceStateRead(for: key).state
    }

    public func sourceStateRead(for key: PendingSourceKey) -> PendingSourceStateRead {
        connection.withLock { sourceStateLocked(key) }
    }

    /// Sources with an effect that is due by `date`.
    public func dueSourceStates(by date: Date) -> [PendingSourceState] {
        dueSourceStatesRead(by: date).states
    }

    /// Due sources that decode, and whether the query succeeded and every due row decoded.
    public func dueSourceStatesRead(by date: Date) -> PendingSourceStatesRead {
        connection.withLock {
            let read = sourceStatesLocked(
                where: "(needs_queue_sync=1 OR needs_remote_trash=1 OR needs_remote_restore=1) AND next_attempt_at <= ?"
            ) { sqlite3_bind_double($0, 1, date.timeIntervalSince1970) }
            return PendingSourceStatesRead(states: read.states, complete: read.succeeded)
        }
    }

    /// The earliest time a deferred effect becomes due, for the reconciler's timer.
    public func nextEffectDate() -> Date? {
        connection.withLock {
            var result: Date?
            _ = query(
                """
                SELECT MIN(next_attempt_at) FROM source_state
                WHERE needs_queue_sync=1 OR needs_remote_trash=1 OR needs_remote_restore=1;
                """
            ) { stmt in
                guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return }
                result = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            }
            return result
        }
    }

    /// Identifiers among `identifiers` whose desired state is excluded, or nil when the store cannot answer.
    /// The backup engine drops these before it writes queue rows.
    public func excludedIdentifiers(kind: UploadSourceIdentity.Kind, among identifiers: [String]) -> Set<String>? {
        guard !identifiers.isEmpty else { return [] }
        return connection.withLock {
            guard db != nil, !connection.operationFailed else { return nil }
            var result = Set<String>()
            var stmt: OpaquePointer?
            guard
                prepare(
                    "SELECT 1 FROM source_state WHERE source_kind=? AND source_id=? AND desired='excluded';",
                    &stmt)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            for identifier in identifiers {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, kind.rawValue)
                bindText(stmt, 2, identifier)
                let step = sqlite3_step(stmt)
                if step == SQLITE_ROW {
                    result.insert(identifier)
                } else if step != SQLITE_DONE {
                    connection.markFailed()
                    return nil
                }
            }
            return result
        }
    }

    /// Writes desired = excluded for each request in one transaction and returns the new states.
    public func exclude(_ requests: [PendingExclusionRequest], at date: Date) -> [PendingSourceState]? {
        guard !requests.isEmpty else { return [] }
        return connection.withLock {
            var states: [PendingSourceState] = []
            let committed = transaction {
                for request in requests {
                    guard case .readable(let previous) = sourceStateLocked(request.key) else { return false }
                    // A commit of the deleted revision is already durable here, even when its event has not reached
                    // the coordinator yet. The earlier upload that the coordinator sends for an edit goes first: the
                    // completed trash of that photo moves on to the latest handoff, see `completeEffect`.
                    let durable = request.revision.flatMap { handoffLocked(request.key, revision: $0)?.remote }
                    // A delete that could not tell its photo names none: the photo that the state still knows can be
                    // another one, and it never goes to the trash on an unknown.
                    let remote = request.remote ?? durable ?? (request.remoteUnknown ? nil : previous?.remote)
                    // A photo that this path trashed stays trashed, unless a restore of it may already have
                    // happened. Otherwise a known remote photo must go to the Proton trash.
                    let alreadyTrashed =
                        previous?.remoteTrashed == true && previous?.remoteOperation != .remoteRestore
                        && remote == previous?.remote
                    let needsTrash = remote != nil && !alreadyTrashed
                    let presentation = request.presentation ?? previous?.presentation
                    guard
                        execute(
                            """
                            INSERT INTO source_state(
                              source_kind, source_id, desired, generation, needs_queue_sync, needs_remote_trash,
                              needs_remote_restore, remote_volume_id, remote_link_id, remote_trashed,
                              listed_in_trash, excluded_at, capture_time, media_type, is_live, duration,
                              display_name, attempts, next_attempt_at, updated_at)
                            VALUES(?, ?, 'excluded', ?, 1, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                            ON CONFLICT(source_kind, source_id) DO UPDATE SET
                              desired='excluded', generation=excluded.generation, needs_queue_sync=1,
                              needs_remote_trash=excluded.needs_remote_trash, needs_remote_restore=0,
                              remote_volume_id=excluded.remote_volume_id, remote_link_id=excluded.remote_link_id,
                              remote_trashed=excluded.remote_trashed, listed_in_trash=excluded.listed_in_trash,
                              excluded_at=excluded.excluded_at, capture_time=excluded.capture_time,
                              media_type=excluded.media_type, is_live=excluded.is_live, duration=excluded.duration,
                              display_name=excluded.display_name, attempts=0,
                              next_attempt_at=excluded.next_attempt_at, updated_at=excluded.updated_at;
                            """,
                            bind: { stmt in
                                bindKey(stmt, request.key)
                                sqlite3_bind_int64(stmt, 3, (previous?.generation ?? 0) + 1)
                                sqlite3_bind_int(stmt, 4, needsTrash ? 1 : 0)
                                bindOptionalText(stmt, 5, remote?.volumeID)
                                bindOptionalText(stmt, 6, remote?.nodeID)
                                sqlite3_bind_int(stmt, 7, alreadyTrashed ? 1 : 0)
                                // A Proton trash entry already represents a photo this path trashed.
                                sqlite3_bind_int(stmt, 8, alreadyTrashed || needsTrash ? 0 : 1)
                                sqlite3_bind_double(stmt, 9, date.timeIntervalSince1970)
                                bindPresentation(stmt, from: 10, presentation)
                                sqlite3_bind_double(stmt, 15, date.timeIntervalSince1970)
                                sqlite3_bind_double(stmt, 16, date.timeIntervalSince1970)
                            }),
                        let state = sourceStateLocked(request.key).state
                    else { return false }
                    states.append(state)
                }
                return true
            }
            return committed ? states : nil
        }
    }

    /// Takes back the trash of `remote` that `exclude` wrote for `generation`, so that photo stays: the delete of an
    /// unfinished edit chose an earlier upload, and the identity manifest could not give it up. A commit of the
    /// deleted revision still goes to the trash. Returns the current state, or nil when the write failed.
    public func keepRemote(
        _ remote: PhotoUID,
        of key: PendingSourceKey,
        generation: Int64,
        revision: UploadBackupRevision?,
        at date: Date
    ) -> PendingSourceState? {
        connection.withLock {
            let durable = revision.flatMap { handoffLocked(key, revision: $0)?.remote }
            guard
                execute(
                    """
                    UPDATE source_state
                    SET needs_remote_trash=?, remote_volume_id=?, remote_link_id=?, remote_trashed=0, listed_in_trash=?,
                        updated_at=?
                    WHERE source_kind=? AND source_id=? AND generation=? AND desired='excluded' AND needs_remote_trash=1
                      AND remote_op IS NULL AND remote_link_id=?;
                    """,
                    bind: { stmt in
                        sqlite3_bind_int(stmt, 1, durable == nil ? 0 : 1)
                        bindOptionalText(stmt, 2, durable?.volumeID)
                        bindOptionalText(stmt, 3, durable?.nodeID)
                        // Like `exclude`: a state without a photo for the trash lists its entry in "Zuletzt gelöscht".
                        sqlite3_bind_int(stmt, 4, durable == nil ? 1 : 0)
                        sqlite3_bind_double(stmt, 5, date.timeIntervalSince1970)
                        bindKey(stmt, key, from: 6)
                        sqlite3_bind_int64(stmt, 8, generation)
                        bindText(stmt, 9, remote.nodeID)
                    })
            else { return nil }
            return sourceStateLocked(key).state
        }
    }

    /// Writes desired = included for excluded sources in one transaction and returns the new states.
    /// Sources without a row were never excluded and are skipped.
    public func include(_ keys: [PendingSourceKey], at date: Date) -> [PendingSourceState]? {
        guard !keys.isEmpty else { return [] }
        return connection.withLock {
            var states: [PendingSourceState] = []
            let committed = transaction {
                for key in keys {
                    guard case .readable(let current) = sourceStateLocked(key) else { return false }
                    guard let previous = current, previous.desired == .excluded else { continue }
                    guard
                        execute(
                            """
                            UPDATE source_state
                            SET desired='included', generation=generation+1, needs_queue_sync=1,
                                needs_remote_trash=0,
                                needs_remote_restore=CASE
                                  WHEN remote_trashed=1 OR remote_op='remoteTrash' THEN 1 ELSE 0
                                END,
                                listed_in_trash=0,
                                attempts=0, next_attempt_at=?, updated_at=?
                            WHERE source_kind=? AND source_id=?;
                            """,
                            bind: { stmt in
                                sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
                                sqlite3_bind_double(stmt, 2, date.timeIntervalSince1970)
                                bindKey(stmt, key, from: 3)
                            }),
                        let state = sourceStateLocked(key).state
                    else { return false }
                    states.append(state)
                }
                return true
            }
            return committed ? states : nil
        }
    }

    /// Marks one effect done for the generation that performed it. A completion always re-reads the current
    /// desired state: a trash that finishes after a restore schedules the remote restore, and a restore that
    /// finishes after a new delete schedules the trash again. Stale generations therefore never undo a newer
    /// decision. An included source without due effects is deleted. `remoteLinkID` names the photo that the
    /// effect handled; a trash of a photo that a later commit replaced leaves the trash of the new photo due.
    /// A finished trash of an excluded source moves on to its latest handoff when that names another photo: the
    /// edit of a deleted photo can commit before the trash of the earlier upload is sent. When that handoff cannot be
    /// read, the trash stays due with the shared backoff, and the result says whether that retry was stored.
    @discardableResult
    public func completeEffect(
        _ effect: PendingSourceEffect,
        for key: PendingSourceKey,
        generation: Int64,
        remoteLinkID: String? = nil,
        at date: Date
    ) -> Bool {
        connection.withLock {
            transaction {
                guard case .readable(let current) = sourceStateLocked(key) else { return false }
                guard let state = current else { return true }
                var sql: String
                var movesOn = false
                switch effect {
                case .queueSync:
                    // A newer generation wrote its own queue sync request; keep it.
                    guard state.generation == generation else { return true }
                    sql = "UPDATE source_state SET needs_queue_sync=0, attempts=0, updated_at=?"
                case .remoteTrash where remoteLinkID != nil && remoteLinkID != state.remote?.nodeID:
                    // A later decision chose another photo for the trash; that trash stays due.
                    sql = "UPDATE source_state SET remote_op=NULL, attempts=0, updated_at=?"
                case .remoteTrash:
                    movesOn = true
                    sql = """
                        UPDATE source_state SET needs_remote_trash=0, remote_trashed=1, listed_in_trash=0, remote_op=NULL,
                          needs_remote_restore=CASE WHEN desired='included' THEN 1 ELSE 0 END, attempts=0, updated_at=?
                        """
                case .remoteRestore:
                    sql = """
                        UPDATE source_state SET needs_remote_restore=0, remote_trashed=0, remote_op=NULL,
                          needs_remote_trash=CASE WHEN desired='excluded' AND remote_link_id IS NOT NULL THEN 1 ELSE 0 END,
                          attempts=0, updated_at=?
                        """
                }
                sql += " WHERE source_kind=? AND source_id=?;"
                var latest: PendingHandoff?
                if movesOn, state.desired == .excluded {
                    // An unreadable handoff is no "no later photo": the trash stays due, so a later upload of the
                    // deleted photo still goes to the trash once the handoff reads again.
                    guard case .readable(let handoff) = latestHandoffLocked(key) else {
                        return deferLocked(state, at: date)
                    }
                    latest = handoff
                }
                let updated = execute(sql) { stmt in
                    sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
                    bindKey(stmt, key, from: 2)
                }
                guard updated else { return false }
                if let latest, latest.remote.nodeID != state.remote?.nodeID {
                    guard
                        execute(
                            """
                            UPDATE source_state
                            SET needs_remote_trash=1, needs_remote_restore=0, remote_volume_id=?, remote_link_id=?,
                                remote_trashed=0, listed_in_trash=0, attempts=0, next_attempt_at=?, updated_at=?
                            WHERE source_kind=? AND source_id=? AND desired='excluded';
                            """,
                            bind: { stmt in
                                bindText(stmt, 1, latest.remote.volumeID)
                                bindText(stmt, 2, latest.remote.nodeID)
                                sqlite3_bind_double(stmt, 3, date.timeIntervalSince1970)
                                sqlite3_bind_double(stmt, 4, date.timeIntervalSince1970)
                                bindKey(stmt, key, from: 5)
                            })
                    else { return false }
                }
                return execute(
                    """
                    DELETE FROM source_state
                    WHERE source_kind=? AND source_id=? AND desired='included' AND remote_op IS NULL
                      AND needs_queue_sync=0 AND needs_remote_trash=0 AND needs_remote_restore=0;
                    """
                ) { bindKey($0, key) }
            }
        }
    }

    /// Marks a trash or restore request as sent, right before the reconciler dispatches it. Only states that
    /// still want this effect for the same generation are marked; the reconciler dispatches exactly those.
    /// Until a confirmed completion clears the marker, new decisions treat the request as possibly done.
    public func beginRemoteOperation(
        _ effect: PendingSourceEffect,
        for states: [PendingSourceState]
    ) -> Set<PendingSourceKey>? {
        guard !states.isEmpty, effect != .queueSync else { return [] }
        return connection.withLock {
            var marked = Set<PendingSourceKey>()
            let condition =
                effect == .remoteTrash
                ? "desired='excluded' AND needs_remote_trash=1" : "desired='included' AND needs_remote_restore=1"
            let committed = transaction {
                for state in states {
                    guard
                        execute(
                            """
                            UPDATE source_state SET remote_op=?
                            WHERE source_kind=? AND source_id=? AND generation=? AND \(condition)
                              AND remote_link_id=?;
                            """,
                            bind: { stmt in
                                bindText(stmt, 1, effect.rawValue)
                                bindKey(stmt, state.key, from: 2)
                                sqlite3_bind_int64(stmt, 4, state.generation)
                                bindText(stmt, 5, state.remote?.nodeID ?? "")
                            })
                    else { return false }
                    if sqlite3_changes(db) > 0 { marked.insert(state.key) }
                }
                return true
            }
            return committed ? marked : nil
        }
    }

    /// Schedules the next attempt of a failed effect with the shared backoff.
    @discardableResult
    public func deferEffects(for key: PendingSourceKey, at date: Date) -> Bool {
        connection.withLock {
            guard case .readable(let current) = sourceStateLocked(key) else { return false }
            guard let state = current else { return true }
            return deferLocked(state, at: date)
        }
    }

    private func deferLocked(_ state: PendingSourceState, at date: Date) -> Bool {
        let next = date.addingTimeInterval(PendingRetrySchedule.delay(afterAttempts: state.attempts))
        return execute(
            "UPDATE source_state SET attempts=attempts+1, next_attempt_at=?, updated_at=? WHERE source_kind=? AND source_id=?;"
        ) { stmt in
            sqlite3_bind_double(stmt, 1, next.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, date.timeIntervalSince1970)
            bindKey(stmt, state.key, from: 3)
        }
    }

    /// "Endgültig löschen" and "Papierkorb leeren": the entry leaves "Zuletzt gelöscht"; the source stays
    /// excluded.
    @discardableResult
    public func unlistFromTrash(_ keys: [PendingSourceKey], at date: Date) -> Bool {
        guard !keys.isEmpty else { return true }
        return connection.withLock {
            transaction {
                keys.allSatisfy { key in
                    execute(
                        "UPDATE source_state SET listed_in_trash=0, updated_at=? WHERE source_kind=? AND source_id=?;"
                    ) { stmt in
                        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
                        bindKey(stmt, key, from: 2)
                    }
                }
            }
        }
    }

    // MARK: - Deferred actions

    /// Stores the desired favorite state of a pending source. A later toggle replaces it.
    @discardableResult
    public func setFavoriteIntent(_ key: PendingSourceKey, favorite: Bool, at date: Date) -> Bool {
        connection.withLock { upsertActionLocked(key, kind: .favorite, albumID: "", desired: favorite, at: date) }
    }

    @discardableResult
    public func addAlbumIntent(_ key: PendingSourceKey, albumID: String, at date: Date) -> Bool {
        connection.withLock { upsertActionLocked(key, kind: .addToAlbum, albumID: albumID, desired: true, at: date) }
    }

    /// The rows that decode. Use `actionsRead()` where a missing row must not count as "nothing owed".
    public func actions() -> [PendingAction] {
        actionsRead().actions
    }

    /// Every action row that decodes, and whether the query succeeded and every row decoded.
    public func actionsRead() -> PendingActionsRead {
        connection.withLock { actionsLocked(where: nil) }
    }

    public func dueActions(by date: Date) -> [PendingAction] {
        dueActionsRead(by: date).actions
    }

    /// Due actions that decode, and whether the query succeeded and every due row decoded.
    public func dueActionsRead(by date: Date) -> PendingActionsRead {
        connection.withLock {
            actionsLocked(where: "failed=0 AND next_attempt_at <= ?") {
                sqlite3_bind_double($0, 1, date.timeIntervalSince1970)
            }
        }
    }

    @discardableResult
    public func retryAction(_ action: PendingAction, at date: Date) -> Bool {
        connection.withLock {
            let next = date.addingTimeInterval(PendingRetrySchedule.delay(afterAttempts: action.attempts))
            // A newer request for the same action replaced this one: leave it untouched.
            return execute(
                """
                UPDATE pending_action SET attempts=attempts+1, next_attempt_at=?
                WHERE source_kind=? AND source_id=? AND kind=? AND album_id=? AND desired=? AND created_at=?;
                """
            ) { stmt in
                sqlite3_bind_double(stmt, 1, next.timeIntervalSince1970)
                bindActionKey(stmt, action, from: 2)
                sqlite3_bind_int(stmt, 6, action.desired ? 1 : 0)
                sqlite3_bind_double(stmt, 7, action.createdAt.timeIntervalSince1970)
            }
        }
    }

    @discardableResult
    public func failAction(_ action: PendingAction) -> Bool {
        connection.withLock {
            execute(
                """
                UPDATE pending_action SET failed=1
                WHERE source_kind=? AND source_id=? AND kind=? AND album_id=? AND desired=? AND created_at=?;
                """
            ) { stmt in
                bindActionKey(stmt, action, from: 1)
                sqlite3_bind_int(stmt, 5, action.desired ? 1 : 0)
                sqlite3_bind_double(stmt, 6, action.createdAt.timeIntervalSince1970)
            }
        }
    }

    /// Deletes a finished action unless a newer request replaced it meanwhile.
    @discardableResult
    public func completeAction(_ action: PendingAction) -> Bool {
        connection.withLock {
            execute(
                """
                DELETE FROM pending_action
                WHERE source_kind=? AND source_id=? AND kind=? AND album_id=? AND desired=? AND created_at=?;
                """
            ) { stmt in
                bindActionKey(stmt, action, from: 1)
                sqlite3_bind_int(stmt, 5, action.desired ? 1 : 0)
                sqlite3_bind_double(stmt, 6, action.createdAt.timeIntervalSince1970)
            }
        }
    }

    // MARK: - Photos saved by the app

    @discardableResult
    public func recordSavedFromApp(localIdentifier: String, remote: PhotoUID, at date: Date) -> Bool {
        connection.withLock {
            execute(
                """
                INSERT INTO saved_from_app(local_id, remote_volume_id, remote_link_id, saved_at) VALUES(?, ?, ?, ?)
                ON CONFLICT(local_id) DO UPDATE SET remote_volume_id=excluded.remote_volume_id,
                  remote_link_id=excluded.remote_link_id, saved_at=excluded.saved_at;
                """
            ) { stmt in
                bindText(stmt, 1, localIdentifier)
                bindText(stmt, 2, remote.volumeID)
                bindText(stmt, 3, remote.nodeID)
                sqlite3_bind_double(stmt, 4, date.timeIntervalSince1970)
            }
        }
    }

    public func savedFromAppIdentifiers() -> Set<String> {
        connection.withLock {
            var result = Set<String>()
            _ = query("SELECT local_id FROM saved_from_app;") { stmt in
                if let id = columnText(stmt, 0) { result.insert(id) }
            }
            return result
        }
    }

    // MARK: - Locked helpers

    private func handoffLocked(_ key: PendingSourceKey, revision: UploadBackupRevision) -> PendingHandoff? {
        handoffsLocked(where: "source_kind=? AND source_id=? AND revision_us=?") { stmt in
            self.bindKey(stmt, key)
            sqlite3_bind_int64(stmt, 3, revision.rawValue)
        }.first
    }

    private func sourceStateLocked(_ key: PendingSourceKey) -> PendingSourceStateRead {
        let read = sourceStatesLocked(where: "source_kind=? AND source_id=?") { self.bindKey($0, key) }
        guard read.succeeded else { return .unreadable }
        return .readable(read.states.first)
    }

    private static let sourceStateColumns = """
        source_kind, source_id, desired, generation, needs_queue_sync, needs_remote_trash, needs_remote_restore,
        remote_volume_id, remote_link_id, remote_trashed, listed_in_trash, excluded_at, capture_time, media_type,
        is_live, duration, display_name, attempts, next_attempt_at, updated_at, remote_op
        """

    private func sourceStatesLocked(
        where condition: String?,
        bind: ((OpaquePointer?) -> Void)? = nil
    ) -> (states: [PendingSourceState], succeeded: Bool) {
        var result: [PendingSourceState] = []
        var decoded = true
        let sql =
            "SELECT \(Self.sourceStateColumns) FROM source_state"
            + (condition.map { " WHERE \($0)" } ?? "") + " ORDER BY source_kind, source_id;"
        let queried = query(sql, bind: bind) { stmt in
            let remoteOperationIsNull = sqlite3_column_type(stmt, 20) == SQLITE_NULL
            let remoteOperation = sourceStateEnumText(stmt, 20).flatMap(PendingSourceEffect.init(rawValue:))
            guard let kind = sourceStateEnumText(stmt, 0).flatMap(UploadSourceIdentity.Kind.init(rawValue:)),
                let identifier = columnText(stmt, 1),
                let desired = sourceStateEnumText(stmt, 2).flatMap(PendingDesiredState.init(rawValue:)),
                remoteOperationIsNull || remoteOperation != nil
            else {
                connection.markFailed()
                decoded = false
                return
            }
            let remote: PhotoUID? =
                if let volume = columnText(stmt, 7), let link = columnText(stmt, 8) {
                    PhotoUID(volumeID: volume, nodeID: link)
                } else {
                    nil
                }
            var presentation: PendingPresentationMetadata?
            if sqlite3_column_type(stmt, 12) != SQLITE_NULL, let mediaType = columnText(stmt, 13) {
                presentation = PendingPresentationMetadata(
                    captureTime: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12)),
                    mediaType: mediaType,
                    isLivePhoto: sqlite3_column_int(stmt, 14) != 0,
                    durationSeconds: sqlite3_column_type(stmt, 15) == SQLITE_NULL
                        ? nil : sqlite3_column_double(stmt, 15),
                    displayName: columnText(stmt, 16) ?? ""
                )
            }
            result.append(
                PendingSourceState(
                    key: PendingSourceKey(kind: kind, identifier: identifier),
                    desired: desired,
                    generation: sqlite3_column_int64(stmt, 3),
                    needsQueueSync: sqlite3_column_int(stmt, 4) != 0,
                    needsRemoteTrash: sqlite3_column_int(stmt, 5) != 0,
                    needsRemoteRestore: sqlite3_column_int(stmt, 6) != 0,
                    remote: remote,
                    remoteTrashed: sqlite3_column_int(stmt, 9) != 0,
                    remoteOperation: remoteOperation,
                    listedInTrash: sqlite3_column_int(stmt, 10) != 0,
                    excludedAt: sqlite3_column_type(stmt, 11) == SQLITE_NULL
                        ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11)),
                    presentation: presentation,
                    attempts: Int(sqlite3_column_int(stmt, 17)),
                    nextAttemptAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 18)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 19))
                ))
        }
        return (result, queried && decoded)
    }

    /// Enum raw values must include every persisted byte, including any embedded NUL.
    private func sourceStateEnumText(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard let text = sqlite3_column_text(stmt, column) else { return nil }
        return String(
            bytes: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(stmt, column))),
            encoding: .utf8)
    }

    private func handoffsLocked(where condition: String, bind: ((OpaquePointer?) -> Void)? = nil) -> [PendingHandoff] {
        var result: [PendingHandoff] = []
        _ = query(
            """
            SELECT source_kind, source_id, revision_us, remote_volume_id, remote_link_id, kind, created_at, acknowledged
            FROM handoff WHERE \(condition) ORDER BY created_at;
            """,
            bind: bind
        ) { stmt in
            if let handoff = handoffRow(stmt) { result.append(handoff) } else { connection.markFailed() }
        }
        return result
    }

    private func handoffRow(_ stmt: OpaquePointer?) -> PendingHandoff? {
        guard let key = key(stmt, kindColumn: 0, idColumn: 1),
            let volume = columnText(stmt, 3),
            let link = columnText(stmt, 4),
            let kind = columnText(stmt, 5).flatMap(PendingHandoffKind.init(rawValue:))
        else { return nil }
        return PendingHandoff(
            key: key,
            revision: UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 2)),
            remote: PhotoUID(volumeID: volume, nodeID: link),
            kind: kind,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
            acknowledged: sqlite3_column_int(stmt, 7) != 0
        )
    }

    private func upsertActionLocked(
        _ key: PendingSourceKey,
        kind: PendingActionKind,
        albumID: String,
        desired: Bool,
        at date: Date
    ) -> Bool {
        execute(
            """
            INSERT INTO pending_action(source_kind, source_id, kind, album_id, desired, created_at, attempts,
                                       next_attempt_at, failed)
            VALUES(?, ?, ?, ?, ?, ?, 0, ?, 0)
            ON CONFLICT(source_kind, source_id, kind, album_id) DO UPDATE SET
              desired=excluded.desired, created_at=excluded.created_at, attempts=0,
              next_attempt_at=excluded.next_attempt_at, failed=0;
            """
        ) { stmt in
            bindKey(stmt, key)
            bindText(stmt, 3, kind.rawValue)
            bindText(stmt, 4, albumID)
            sqlite3_bind_int(stmt, 5, desired ? 1 : 0)
            sqlite3_bind_double(stmt, 6, date.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 7, date.timeIntervalSince1970)
        }
    }

    private func actionsLocked(
        where condition: String?, bind: ((OpaquePointer?) -> Void)? = nil
    ) -> PendingActionsRead {
        var result: [PendingAction] = []
        var decoded = true
        let sql =
            """
            SELECT source_kind, source_id, kind, album_id, desired, created_at, attempts, next_attempt_at, failed
            FROM pending_action
            """ + (condition.map { " WHERE \($0)" } ?? "") + " ORDER BY created_at;"
        let succeeded = query(sql, bind: bind) { stmt in
            guard let key = key(stmt, kindColumn: 0, idColumn: 1),
                let kind = columnText(stmt, 2).flatMap(PendingActionKind.init(rawValue:))
            else {
                connection.markFailed()
                decoded = false
                return
            }
            result.append(
                PendingAction(
                    key: key,
                    kind: kind,
                    albumID: columnText(stmt, 3) ?? "",
                    desired: sqlite3_column_int(stmt, 4) != 0,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                    attempts: Int(sqlite3_column_int(stmt, 6)),
                    nextAttemptAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
                    failed: sqlite3_column_int(stmt, 8) != 0
                ))
        }
        return PendingActionsRead(actions: result, complete: succeeded && decoded)
    }

    // MARK: - SQLite plumbing

    /// Runs `body` in one IMMEDIATE transaction. Returns false and rolls back when `body` or the commit fails.
    private func transaction(_ body: () -> Bool) -> Bool {
        guard db != nil, sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            connection.markFailed()
            return false
        }
        guard body(), sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            connection.markFailed()
            return false
        }
        return true
    }

    private func prepare(_ sql: String, _ stmt: inout OpaquePointer?) -> Bool {
        guard db != nil, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            stmt = nil
            connection.markFailed()
            return false
        }
        return true
    }

    private func execute(_ sql: String, bind: (OpaquePointer?) -> Void) -> Bool {
        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            connection.markFailed()
            return false
        }
        return true
    }

    private func query(
        _ sql: String,
        bind: ((OpaquePointer?) -> Void)? = nil,
        row: (OpaquePointer?) -> Void
    ) -> Bool {
        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) else { return false }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt)
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            row(stmt)
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else {
            connection.markFailed()
            return false
        }
        return true
    }

    private func key(_ stmt: OpaquePointer?, kindColumn: Int32, idColumn: Int32) -> PendingSourceKey? {
        guard let kind = columnText(stmt, kindColumn).flatMap(UploadSourceIdentity.Kind.init(rawValue:)),
            let identifier = columnText(stmt, idColumn)
        else { return nil }
        return PendingSourceKey(kind: kind, identifier: identifier)
    }

    private func bindKey(_ stmt: OpaquePointer?, _ key: PendingSourceKey, from index: Int32 = 1) {
        bindText(stmt, index, key.kind.rawValue)
        bindText(stmt, index + 1, key.identifier)
    }

    private func bindActionKey(_ stmt: OpaquePointer?, _ action: PendingAction, from index: Int32) {
        bindKey(stmt, action.key, from: index)
        bindText(stmt, index + 2, action.kind.rawValue)
        bindText(stmt, index + 3, action.albumID)
    }

    /// Binds capture_time, media_type, is_live, duration, display_name starting at `index`.
    private func bindPresentation(_ stmt: OpaquePointer?, from index: Int32, _ value: PendingPresentationMetadata?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            sqlite3_bind_null(stmt, index + 1)
            sqlite3_bind_int(stmt, index + 2, 0)
            sqlite3_bind_null(stmt, index + 3)
            sqlite3_bind_null(stmt, index + 4)
            return
        }
        sqlite3_bind_double(stmt, index, value.captureTime.timeIntervalSince1970)
        bindText(stmt, index + 1, value.mediaType)
        sqlite3_bind_int(stmt, index + 2, value.isLivePhoto ? 1 : 0)
        if let duration = value.durationSeconds {
            sqlite3_bind_double(stmt, index + 3, duration)
        } else {
            sqlite3_bind_null(stmt, index + 3)
        }
        bindText(stmt, index + 4, value.displayName)
    }

    private let transient = SQLiteStoreSchemaGate.transientDestructor

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { bindText(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: text)
    }

    // MARK: - Schema

    private static func openOnce(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        let schema = """
            CREATE TABLE IF NOT EXISTS pending_info(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS source_state(
              source_kind          TEXT NOT NULL,
              source_id            TEXT NOT NULL,
              desired              TEXT NOT NULL,
              generation           INTEGER NOT NULL,
              needs_queue_sync     INTEGER NOT NULL,
              needs_remote_trash   INTEGER NOT NULL,
              needs_remote_restore INTEGER NOT NULL,
              remote_volume_id     TEXT,
              remote_link_id       TEXT,
              remote_trashed       INTEGER NOT NULL,
              listed_in_trash      INTEGER NOT NULL,
              excluded_at          REAL,
              capture_time         REAL,
              media_type           TEXT,
              is_live              INTEGER NOT NULL,
              duration             REAL,
              display_name         TEXT,
              attempts             INTEGER NOT NULL,
              next_attempt_at      REAL NOT NULL,
              updated_at           REAL NOT NULL,
              remote_op            TEXT,
              PRIMARY KEY(source_kind, source_id)
            );
            CREATE TABLE IF NOT EXISTS upload_evidence(
              source_kind TEXT NOT NULL,
              source_id   TEXT NOT NULL,
              revision_us INTEGER NOT NULL,
              recorded_at REAL NOT NULL,
              PRIMARY KEY(source_kind, source_id, revision_us)
            );
            CREATE TABLE IF NOT EXISTS handoff(
              source_kind      TEXT NOT NULL,
              source_id        TEXT NOT NULL,
              revision_us      INTEGER NOT NULL,
              remote_volume_id TEXT NOT NULL,
              remote_link_id   TEXT NOT NULL,
              kind             TEXT NOT NULL,
              created_at       REAL NOT NULL,
              acknowledged     INTEGER NOT NULL,
              PRIMARY KEY(source_kind, source_id, revision_us)
            );
            CREATE INDEX IF NOT EXISTS handoff_acknowledged_idx ON handoff(acknowledged, created_at);
            CREATE INDEX IF NOT EXISTS handoff_remote_idx ON handoff(remote_link_id);
            CREATE TABLE IF NOT EXISTS pending_action(
              source_kind     TEXT NOT NULL,
              source_id       TEXT NOT NULL,
              kind            TEXT NOT NULL,
              album_id        TEXT NOT NULL,
              desired         INTEGER NOT NULL,
              created_at      REAL NOT NULL,
              attempts        INTEGER NOT NULL,
              next_attempt_at REAL NOT NULL,
              failed          INTEGER NOT NULL,
              PRIMARY KEY(source_kind, source_id, kind, album_id)
            );
            CREATE TABLE IF NOT EXISTS saved_from_app(
              local_id         TEXT PRIMARY KEY,
              remote_volume_id TEXT NOT NULL,
              remote_link_id   TEXT NOT NULL,
              saved_at         REAL NOT NULL
            );
            """

        return SQLiteStoreSchemaGate.openCurrentStore(
            at: url,
            schemaSQL: schema,
            policy: policy,
            verifyVersion: verifyVersion,
            stampVersion: stampVersion
        )
    }

    private static func verifyVersion(_ handle: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(handle, "SELECT value FROM pending_info WHERE key='schema';", -1, &stmt, nil)
                == SQLITE_OK
        else { return false }
        var onDisk: Int?
        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW { onDisk = Int(sqlite3_column_int(stmt, 0)) }
        sqlite3_finalize(stmt)
        return result == SQLITE_ROW && onDisk == schemaVersion
    }

    private static func stampVersion(_ handle: OpaquePointer?) -> Bool {
        sqlite3_exec(
            handle,
            "INSERT INTO pending_info(key, value) VALUES('schema', \(schemaVersion)) "
                + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
            nil, nil, nil
        ) == SQLITE_OK
    }
}
