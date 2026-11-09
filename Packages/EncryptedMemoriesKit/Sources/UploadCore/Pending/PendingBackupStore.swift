import Foundation
import PhotosCore
import SQLite3

/// Device-local state for pending grid tiles (`pending-backup-v1.sqlite`): desired backup state per source,
/// duplicate-check evidence, handoffs to Proton photos, deferred actions and photos the app saved itself.
///
/// It is a separate store so changes to pending state cannot change the backup queue schema. Only the exact
/// supported v1 schema migrates to v2; unknown schemas stay untouched. Writes are synchronous so the backup runner can record a
/// handoff before it clears a commit receipt. An unavailable store fails closed: no pending tile shows,
/// and the backup engine enqueues no new photos, because it cannot prove that they were not deleted.
public final class PendingBackupManifestStore: @unchecked Sendable {
    public static let databaseFileName = "pending-backup-v1.sqlite"

    private static let schemaVersion = 2
    private let connection: SQLiteStoreConnection
    private var db: OpaquePointer? { connection.database }

    public init?(url: URL, policy: LibraryDatabasePolicy = .conservative) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let handle = Self.openOnce(url: url, policy: policy) else { return nil }
        connection = SQLiteStoreConnection(database: handle)
    }

    deinit { close() }

    public func close() { connection.close() }

    /// A failed call stops the store only until the database answers again, see
    /// `SQLiteStoreConnection.isOperationalAfterRecovery()`. A row that does not decode never stops it (#982).
    public func isOperational() -> Bool { connection.isOperationalAfterRecovery() }

    // MARK: - Duplicate-check evidence

    /// The runner decided after the duplicate check that this revision needs an upload.
    @discardableResult
    public func recordUploadEvidence(_ key: PendingSourceKey, revision: UploadBackupRevision, at date: Date) -> Bool {
        standaloneWrite(refusing: false) {
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
                // A handoff of this revision that this build cannot read stays as it is (#982).
                guard case .readable = handoffReadLocked(handoff.key, revision: handoff.revision) else { return false }
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
                guard !handoff.remote.nodeID.isEmpty,
                    let duties = trashDutiesLocked(for: handoff.key, generation: state.generation)
                else { return false }
                // Receipt replay must not re-arm a photo this delete already trashed.
                if duties.completed.contains(handoff.remote) { return true }
                guard
                    writeTrashMetadata(
                        for: handoff.key, remote: handoff.remote, completed: false, generation: state.generation)
                else { return false }
                // The delete of an unfinished edit still owes the trash of the earlier upload. That photo stays the
                // state's photo; its completed trash moves on to this handoff, see `completeEffectResult`.
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

    /// The latest handoff of each source, or `unreadable` when its query failed or its row did not decode. A failed
    /// prepare records a failure like every call; a failed step and a row that does not decode record none.
    public func latestHandoffsRead(for keys: [PendingSourceKey]) -> [PendingSourceKey: PendingHandoffRead] {
        guard !keys.isEmpty else { return [:] }
        return connection.withLock {
            var result: [PendingSourceKey: PendingHandoffRead] = [:]
            var stmt: OpaquePointer?
            guard prepare(Self.latestHandoffSQL, &stmt) else {
                // As before, the failed prepare answers the first key; every other key prepares again.
                result[keys[0]] = .unreadable
                for key in keys.dropFirst() { result[key] = latestHandoffLocked(key) }
                return result
            }
            defer { sqlite3_finalize(stmt) }
            // One statement serves every key. Each key starts from a reset statement without bindings.
            for key in keys {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                result[key] = latestHandoffLocked(key, stmt)
            }
            return result
        }
    }

    private static let latestHandoffSQL = """
        SELECT source_kind, source_id, revision_us, remote_volume_id, remote_link_id, kind,
               created_at, acknowledged
        FROM handoff WHERE source_kind=? AND source_id=?
        ORDER BY created_at DESC, revision_us DESC LIMIT 1;
        """

    private func latestHandoffLocked(_ key: PendingSourceKey) -> PendingHandoffRead {
        var stmt: OpaquePointer?
        guard prepare(Self.latestHandoffSQL, &stmt) else { return .unreadable }
        defer { sqlite3_finalize(stmt) }
        return latestHandoffLocked(key, stmt)
    }

    private func latestHandoffLocked(_ key: PendingSourceKey, _ stmt: OpaquePointer?) -> PendingHandoffRead {
        bindKey(stmt, key)
        switch sqlite3_step(stmt) {
        case SQLITE_ROW:
            guard let handoff = handoffRow(stmt) else {
                Self.noteUndecodableRow()
                return .unreadable
            }
            return .readable(handoff)
        case SQLITE_DONE: return .readable(nil)
        default: return .unreadable
        }
    }

    /// Only SQLITE_DONE for every requested link, with every row decoded, proves a complete lookup.
    public func handoffsRead(forRemoteLinkIDs linkIDs: [String]) -> PendingHandoffsRead {
        guard !linkIDs.isEmpty else { return .complete([]) }
        return connection.withLock {
            var result: [PendingHandoff] = []
            for linkID in linkIDs {
                let read = handoffsReadLocked(where: "remote_link_id=?") { self.bindText($0, 1, linkID) }
                guard read.complete else { return .unreadable }
                result += read.handoffs
            }
            return .complete(result)
        }
    }

    @discardableResult
    public func acknowledgeHandoffs(_ handoffs: [(PendingSourceKey, UploadBackupRevision)]) -> Bool {
        guard !handoffs.isEmpty else { return true }
        return connection.withLock {
            transaction {
                handoffs.allSatisfy { key, revision in
                    execute(
                        "UPDATE handoff SET acknowledged=1 WHERE source_kind=? AND source_id=? AND revision_us=? "
                            + "AND kind IN (\(Self.sqlList(PendingHandoffKind.self)));"
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
        standaloneWrite(refusing: false) {
            // Unfinished work needs its handoffs. A completed trash also keeps its handoffs until the source
            // returns to the backup: a restart may still have to discover its later upload.
            execute(
                """
                DELETE FROM handoff
                WHERE acknowledged=1 AND created_at < ?
                  AND source_kind IN (\(Self.sqlList(UploadSourceIdentity.Kind.self)))
                  AND kind IN (\(Self.sqlList(PendingHandoffKind.self)))
                  AND remote_volume_id IS NOT NULL AND remote_link_id IS NOT NULL
                  AND NOT EXISTS (
                    SELECT 1 FROM source_state u
                    WHERE u.source_id=handoff.source_id
                      AND (u.source_kind NOT IN (\(Self.sqlList(UploadSourceIdentity.Kind.self)))
                        OR u.desired NOT IN (\(Self.sqlList(PendingDesiredState.self)))
                        OR (u.remote_op IS NOT NULL AND u.remote_op NOT IN (\(Self.sqlList(PendingSourceEffect.self)))))
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM pending_action a
                    WHERE a.source_kind=handoff.source_kind AND a.source_id=handoff.source_id AND a.failed=0
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM source_state s
                    WHERE s.source_kind=handoff.source_kind AND s.source_id=handoff.source_id
                      AND (s.needs_remote_trash=1 OR (
                        s.desired='excluded' AND s.remote_trashed=1
                      ))
                  );
                """
            ) { sqlite3_bind_double($0, 1, cutoff.timeIntervalSince1970) }
        }
    }

    // MARK: - Desired state

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

    /// The identifiers among `identifiers` that are excluded or have a row that this build cannot read, or nil when
    /// the store cannot answer. An identifier that is missing from the result is included. A row that this build cannot
    /// read may hold a newer build's exclusion: that photo waits and its row stays; the other photos go on (#982).
    /// An earlier transient failure does not stop this read. A lasting failure, an open transaction or a failure of
    /// this read answers nil, so no photo uploads while its exclusion is unknown.
    public func exclusions(
        kind: UploadSourceIdentity.Kind, among identifiers: [String]
    ) -> [String: BackupSourceExclusion]? {
        guard !identifiers.isEmpty else { return [:] }
        return connection.withLock {
            guard db != nil, sqlite3_get_autocommit(db) != 0,
                !connection.operationFailed || connection.failuresAreTransient
            else { return nil }
            var result: [String: BackupSourceExclusion] = [:]
            // A row whose kind does not decode still belongs to its identifier, whatever its kind: the reads cover the
            // known kinds and every gap between them.
            var seen = Set<String>()
            let unique = identifiers.filter { seen.insert($0).inserted }
            for start in stride(from: 0, to: unique.count, by: Self.identifierChunkSize) {
                let chunk = unique[start..<min(start + Self.identifierChunkSize, unique.count)]
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for kindFilter in Self.sourceKindFilters {
                    let read = query(
                        "SELECT source_kind, source_id, desired, remote_op FROM source_state "
                            + "WHERE \(kindFilter) AND source_id IN (\(placeholders));",
                        bind: { stmt in
                            for (offset, identifier) in chunk.enumerated() {
                                self.bindText(stmt, Int32(offset + 1), identifier)
                            }
                        }
                    ) { stmt in
                        guard let identifier = columnText(stmt, 1) else { return }
                        let rowKind = columnText(stmt, 0, roundTrip: true).flatMap(
                            UploadSourceIdentity.Kind.init(rawValue:))
                        let desired = columnText(stmt, 2, roundTrip: true).flatMap(PendingDesiredState.init(rawValue:))
                        let operationReadable =
                            sqlite3_column_type(stmt, 3) == SQLITE_NULL
                            || columnText(stmt, 3, roundTrip: true).flatMap(PendingSourceEffect.init(rawValue:)) != nil
                        guard let rowKind, let desired, operationReadable else {
                            Self.noteUndecodableRow()
                            result[identifier] = .unreadable
                            return
                        }
                        if rowKind == kind, desired == .excluded, result[identifier] == nil {
                            result[identifier] = .excluded
                        }
                    }
                    guard read else { return nil }
                }
            }
            return result
        }
    }

    /// Identifiers in one read; far below SQLite's limit of bound parameters.
    private static let identifierChunkSize = 500

    /// The kinds that this build knows, read by key, and the gaps before, between and after them, read as ranges of
    /// the key. Together they cover every kind, and no read scans the table (#982).
    private static let sourceKindFilters: [String] = {
        let known = UploadSourceIdentity.Kind.allCases.map(\.rawValue).sorted()
        var filters = ["source_kind IN (\(sqlList(UploadSourceIdentity.Kind.self)))", "source_kind < '\(known[0])'"]
        for (lower, upper) in zip(known, known.dropFirst()) {
            filters.append("source_kind > '\(lower)' AND source_kind < '\(upper)'")
        }
        filters.append("source_kind > '\(known[known.count - 1])'")
        return filters
    }()

    /// The raw values of `type` as an SQL list, for a statement that must not touch a row this build cannot read.
    private static func sqlList<Value: RawRepresentable & CaseIterable>(_ type: Value.Type) -> String
    where Value.RawValue == String {
        type.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
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
                    // completed trash of that photo moves on to the latest handoff, see `completeEffectResult`.
                    var durable: PhotoUID?
                    if let revision = request.revision {
                        guard case .readable(let handoff) = handoffReadLocked(request.key, revision: revision) else {
                            return false
                        }
                        durable = handoff?.remote
                    }
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
                    guard
                        resetTrashDuties(
                            for: request.key, generation: previous?.generation ?? 0,
                            nextGeneration: request.remoteUnknown ? nil : state.generation)
                    else { return false }
                    var owedCommits = Set<PhotoUID>(durable.map { [$0] } ?? [])
                    // An unknown handoff must not reject the stored delete or claim its initial inventory is complete.
                    // Its existing earlier-upload retry keeps the legacy latest-handoff recovery after proof arrives.
                    if let revision = request.revision, remote != nil, !request.remoteUnknown {
                        guard case .readable(let latest) = latestHandoffLocked(request.key) else { return false }
                        if let latest, latest.revision >= revision { owedCommits.insert(latest.remote) }
                    }
                    for commit in owedCommits {
                        guard
                            writeTrashMetadata(
                                for: request.key, remote: commit, completed: false, generation: state.generation)
                        else { return false }
                    }
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
        standaloneWrite(refusing: nil) {
            var durable: PhotoUID?
            if let revision {
                guard case .readable(let handoff) = handoffReadLocked(key, revision: revision) else { return nil }
                durable = handoff?.remote
            }
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

    /// Sends `remote` to the trash for the delete `generation` of an unfinished edit that named no photo, because the
    /// handoff of the edit could not be read then. Only that same delete, still without a photo and without a remote
    /// operation, takes it; a restore or a later delete changed the generation, and a commit of the deleted revision
    /// already named its own photo. Returns the current state, or nil when the write failed.
    public func trashEarlierUpload(
        _ remote: PhotoUID,
        of key: PendingSourceKey,
        generation: Int64,
        at date: Date
    ) -> PendingSourceState? {
        standaloneWrite(refusing: nil) {
            guard
                execute(
                    """
                    UPDATE source_state
                    SET needs_remote_trash=1, remote_volume_id=?, remote_link_id=?, remote_trashed=0, listed_in_trash=0,
                        attempts=0, next_attempt_at=?, updated_at=?
                    WHERE source_kind=? AND source_id=? AND generation=? AND desired='excluded' AND needs_remote_trash=0
                      AND remote_op IS NULL AND remote_volume_id IS NULL AND remote_link_id IS NULL;
                    """,
                    bind: { stmt in
                        bindText(stmt, 1, remote.volumeID)
                        bindText(stmt, 2, remote.nodeID)
                        sqlite3_bind_double(stmt, 3, date.timeIntervalSince1970)
                        sqlite3_bind_double(stmt, 4, date.timeIntervalSince1970)
                        bindKey(stmt, key, from: 5)
                        sqlite3_bind_int64(stmt, 7, generation)
                    })
            else { return nil }
            return sourceStateLocked(key).state
        }
    }

    /// Writes desired = included for excluded sources in one transaction and returns the new states.
    /// Sources without a row were never excluded and are skipped.
    public func include(_ keys: [PendingSourceKey], at date: Date) -> [PendingSourceState]? {
        include(keys, confirmedLinkIDs: [], at: date)
    }

    /// Only matching current targets count as restored. Other sources keep their ordinary restore compensation.
    /// Keep the stored UID as provenance and an in-flight operation until its callback.
    public func includeRestoredInProton(
        _ keys: [PendingSourceKey], confirmedRemotes: [PhotoUID], at date: Date
    ) -> [PendingSourceState]? {
        include(keys, confirmedLinkIDs: Set(confirmedRemotes.map(\.nodeID)), at: date)
    }

    private func include(
        _ keys: [PendingSourceKey], confirmedLinkIDs: Set<String>, at date: Date
    ) -> [PendingSourceState]? {
        guard !keys.isEmpty else { return [] }
        return connection.withLock {
            var states: [PendingSourceState] = []
            let committed = transaction {
                for key in keys {
                    guard case .readable(let current) = sourceStateLocked(key) else { return false }
                    guard let previous = current, previous.desired == .excluded else {
                        if !confirmedLinkIDs.isEmpty { return false }
                        continue
                    }
                    let restoredInProton = previous.remote.map { confirmedLinkIDs.contains($0.nodeID) } == true
                    guard resetTrashDuties(for: key, generation: previous.generation, nextGeneration: nil) else {
                        return false
                    }
                    guard
                        execute(
                            """
                            UPDATE source_state
                            SET desired='included', generation=generation+1, needs_queue_sync=1,
                                needs_remote_trash=0,
                                needs_remote_restore=CASE
                                  WHEN ?=1 THEN 0
                                  WHEN remote_trashed=1 OR remote_op='remoteTrash' THEN 1 ELSE 0
                                END,
                                remote_trashed=CASE WHEN ?=1 THEN 0 ELSE remote_trashed END,
                                listed_in_trash=0,
                                attempts=0, next_attempt_at=?, updated_at=?
                            WHERE source_kind=? AND source_id=?;
                            """,
                            bind: { stmt in
                                sqlite3_bind_int(stmt, 1, restoredInProton ? 1 : 0)
                                sqlite3_bind_int(stmt, 2, restoredInProton ? 1 : 0)
                                sqlite3_bind_double(stmt, 3, date.timeIntervalSince1970)
                                sqlite3_bind_double(stmt, 4, date.timeIntervalSince1970)
                                bindKey(stmt, key, from: 5)
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

    enum EffectCompletionResult: Sendable, Equatable {
        case failed, saved, laterHandoffUnreadable
    }

    /// Marks one effect done for the generation that performed it. A completion always re-reads the current
    /// desired state: a trash that finishes after a restore schedules the remote restore, and a restore that
    /// finishes after a new delete schedules the trash again. Stale generations therefore never undo a newer
    /// decision. An included source without due effects is deleted. `remoteLinkID` names the photo that the
    /// effect handled; a trash of a photo that a later commit replaced leaves the trash of the new photo due.
    /// A finished trash of an excluded source moves on to every recorded duty; legacy state keeps its latest handoff: the
    /// edit of a deleted photo can commit before the trash of the earlier upload is sent.
    ///
    /// A confirmed completion and the discovery of its next photo are separate durable steps. A failed lookup must
    /// never make the coordinator replay the completion of a photo that is already saved as trashed.
    func completeEffectResult(
        _ effect: PendingSourceEffect,
        for key: PendingSourceKey,
        generation: Int64,
        remoteLinkID: String? = nil,
        at date: Date
    ) -> EffectCompletionResult {
        connection.withLock {
            var movesOn = false
            let committed = transaction {
                guard case .readable(let current) = sourceStateLocked(key) else { return false }
                guard let state = current else { return true }
                if effect != .queueSync {
                    guard let matches = operationMatches(effect, key: key, generation: generation, linkID: remoteLinkID)
                    else { return false }
                    guard matches else { return true }
                }
                var sql: String
                switch effect {
                case .queueSync:
                    // A newer generation wrote its own queue sync request; keep it.
                    guard state.generation == generation else { return true }
                    sql = "UPDATE source_state SET needs_queue_sync=0, attempts=0, updated_at=?"
                case .remoteTrash where remoteLinkID != nil && remoteLinkID != state.remote?.nodeID:
                    // A later decision chose another photo for the trash; that trash stays due.
                    sql = "UPDATE source_state SET remote_op=NULL, attempts=0, updated_at=?"
                case .remoteTrash
                where state.generation != generation && state.desired == .included
                    && remoteLinkID != nil && remoteLinkID == state.remote?.nodeID
                    && state.remoteOperation == .remoteTrash && !state.remoteTrashed && !state.needsRemoteRestore:
                    // The trash applied before a confirmed Proton restore; only its acknowledgement was delayed.
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
                if movesOn, state.desired == .excluded, state.generation == generation, let remote = state.remote {
                    guard trashDutiesLocked(for: key, generation: generation) != nil,
                        writeTrashMetadata(for: key, remote: remote, completed: true, generation: generation)
                    else { return false }
                }
                sql += " WHERE source_kind=? AND source_id=?;"
                let updated = execute(sql) { stmt in
                    sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
                    bindKey(stmt, key, from: 2)
                }
                guard updated else { return false }
                if effect != .queueSync, !clearOperationBinding(for: key) { return false }
                return deleteSettledIncludedLocked(key)
            }
            guard committed else { return .failed }
            guard movesOn else { return .saved }
            return resumeLaterTrashLocked(for: key, at: date) == .unreadable ? .laterHandoffUnreadable : .saved
        }
    }

    enum LaterTrashResult: Sendable, Equatable {
        case unchanged, scheduled, unreadable
    }

    /// Used by completion, retry and startup. Each key has its own transaction, so a failed read or write of one
    /// source cannot roll back another source's progress.
    func resumeLaterTrash(for key: PendingSourceKey, at date: Date) -> LaterTrashResult {
        connection.withLock { resumeLaterTrashLocked(for: key, at: date) }
    }

    private func resumeLaterTrashLocked(for key: PendingSourceKey, at date: Date) -> LaterTrashResult {
        var result = LaterTrashResult.unchanged
        let committed = transaction {
            guard case .readable(let current) = sourceStateLocked(key) else { return false }
            // A newer decision, outstanding operation or already scheduled target owns its own work.
            guard let state = current, state.desired == .excluded, state.remoteTrashed,
                !state.needsRemoteTrash, !state.needsRemoteRestore, state.remoteOperation == nil,
                let previous = state.remote
            else { return true }
            guard case .readable(let latest) = latestHandoffLocked(key),
                let duties = trashDutiesLocked(for: key, generation: state.generation)
            else {
                result = .unreadable
                return true
            }
            let target: PhotoUID?
            if let latest, latest.remote != previous, !duties.completed.contains(latest.remote),
                duties.owed.contains(latest.remote) || !duties.generationKnown
            {
                target = latest.remote
            } else {
                target =
                    duties.owed.filter { $0 != previous }.sorted {
                        ($0.volumeID, $0.nodeID) < ($1.volumeID, $1.nodeID)
                    }.first
            }
            guard let target else { return true }
            guard
                execute(
                    """
                    UPDATE source_state
                    SET needs_remote_trash=1, needs_remote_restore=0, remote_volume_id=?, remote_link_id=?,
                        remote_trashed=0, listed_in_trash=0, attempts=0, next_attempt_at=?, updated_at=?
                    WHERE source_kind=? AND source_id=? AND desired='excluded';
                    """,
                    bind: { stmt in
                        bindText(stmt, 1, target.volumeID)
                        bindText(stmt, 2, target.nodeID)
                        sqlite3_bind_double(stmt, 3, date.timeIntervalSince1970)
                        sqlite3_bind_double(stmt, 4, date.timeIntervalSince1970)
                        bindKey(stmt, key, from: 5)
                    })
            else { return false }
            result = .scheduled
            return true
        }
        return committed ? result : .unreadable
    }

    /// Versioned integer metadata adds no schema objects. A generation marker means its initial
    /// handoff selection is known. A legacy or unreadable-handoff delete keeps its former latest-handoff recovery.
    private struct TrashDuties {
        var generationKnown = false
        var owed = Set<PhotoUID>()
        var completed = Set<PhotoUID>()
    }

    private static func trashMetadataPrefix(for key: PendingSourceKey) -> String {
        "pending-trash:" + Data(key.kind.rawValue.utf8).base64EncodedString() + ":"
            + Data(key.identifier.utf8).base64EncodedString() + ":"
    }

    private static func trashMetadataKey(for key: PendingSourceKey, remote: PhotoUID, completed: Bool) -> String {
        trashMetadataPrefix(for: key) + "v1:" + Data(remote.volumeID.utf8).base64EncodedString() + ":"
            + Data(remote.nodeID.utf8).base64EncodedString() + (completed ? ":completed" : ":owed")
    }

    private func trashDutiesLocked(for key: PendingSourceKey, generation: Int64) -> TrashDuties? {
        guard generation >= 0 else { return nil }
        let prefix = Self.trashMetadataPrefix(for: key)
        var result = TrashDuties()
        var decoded = true
        let succeeded = query(
            "SELECT key, value FROM pending_info WHERE key GLOB ?;",
            bind: { stmt in
                // Base64 and the fixed prefix contain no GLOB metacharacters. GLOB keeps case-sensitive source identity.
                self.bindText(stmt, 1, prefix + "*")
            },
            row: { stmt in
                guard let encoded = columnText(stmt, 0, roundTrip: true), sqlite3_column_type(stmt, 1) == SQLITE_INTEGER
                else {
                    decoded = false
                    return
                }
                let storedGeneration = sqlite3_column_int64(stmt, 1)
                guard storedGeneration >= 0, storedGeneration <= generation else {
                    decoded = false
                    return
                }
                let versioned = String(encoded.dropFirst(prefix.count))
                guard versioned.hasPrefix("v1:") else {
                    decoded = false
                    return
                }
                let suffix = String(versioned.dropFirst(3))
                if suffix == "generation" {
                    result.generationKnown = storedGeneration == generation
                    return
                }
                let fields = suffix.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 3, let volumeBytes = Data(base64Encoded: fields[0]),
                    let linkBytes = Data(base64Encoded: fields[1]),
                    let volume = String(data: volumeBytes, encoding: .utf8),
                    let link = String(data: linkBytes, encoding: .utf8), !link.isEmpty,
                    fields[2] == "owed" || fields[2] == "completed"
                else {
                    decoded = false
                    return
                }
                let remote = PhotoUID(volumeID: volume, nodeID: link)
                guard encoded == Self.trashMetadataKey(for: key, remote: remote, completed: fields[2] == "completed")
                else {
                    decoded = false
                    return
                }
                guard storedGeneration == generation else { return }
                if fields[2] == "completed" { result.completed.insert(remote) } else { result.owed.insert(remote) }
            })
        guard succeeded, decoded else { return nil }
        result.owed.subtract(result.completed)
        return result
    }

    private func writeTrashMetadata(
        for key: PendingSourceKey, remote: PhotoUID, completed: Bool, generation: Int64
    ) -> Bool {
        writeTrashMetadata(
            key: Self.trashMetadataKey(for: key, remote: remote, completed: completed), generation: generation)
    }

    private func writeTrashMetadata(key: String, generation: Int64) -> Bool {
        execute(
            "INSERT INTO pending_info(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
        ) { stmt in
            bindText(stmt, 1, key)
            sqlite3_bind_int64(stmt, 2, generation)
        }
    }

    /// A stored restore or new delete ends the prior generation. Refuse unknown metadata before removing any row.
    private func resetTrashDuties(for key: PendingSourceKey, generation: Int64, nextGeneration: Int64?) -> Bool {
        guard trashDutiesLocked(for: key, generation: generation) != nil else { return false }
        guard
            execute(
                "DELETE FROM pending_info WHERE key GLOB ?;",
                bind: { stmt in
                    bindText(stmt, 1, Self.trashMetadataPrefix(for: key) + "*")
                })
        else { return false }
        guard let nextGeneration else { return true }
        return writeTrashMetadata(key: Self.trashMetadataPrefix(for: key) + "v1:generation", generation: nextGeneration)
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
                              AND remote_link_id=?
                              AND (remote_op IS NULL OR remote_op IN (\(Self.sqlList(PendingSourceEffect.self))));
                            """,
                            bind: { stmt in
                                bindText(stmt, 1, effect.rawValue)
                                bindKey(stmt, state.key, from: 2)
                                sqlite3_bind_int64(stmt, 4, state.generation)
                                bindText(stmt, 5, state.remote?.nodeID ?? "")
                            })
                    else { return false }
                    if sqlite3_changes(db) > 0 {
                        guard
                            execute(
                                """
                                INSERT INTO remote_operation(source_kind, source_id, effect, remote_volume_id, remote_link_id, generation)
                                VALUES(?, ?, ?, ?, ?, ?)
                                ON CONFLICT(source_kind, source_id) DO UPDATE SET effect=excluded.effect,
                                  remote_volume_id=excluded.remote_volume_id, remote_link_id=excluded.remote_link_id,
                                  generation=excluded.generation;
                                """,
                                bind: { stmt in
                                    bindKey(stmt, state.key)
                                    bindText(stmt, 3, effect.rawValue)
                                    bindText(stmt, 4, state.remote?.volumeID ?? "")
                                    bindText(stmt, 5, state.remote?.nodeID ?? "")
                                    sqlite3_bind_int64(stmt, 6, state.generation)
                                })
                        else { return false }
                        marked.insert(state.key)
                    }
                }
                return true
            }
            return committed ? marked : nil
        }
    }

    /// No row is legacy unknown ownership. A read error or malformed binding never means absence.
    private func operationMatches(
        _ effect: PendingSourceEffect, key: PendingSourceKey, generation: Int64, linkID: String?
    ) -> Bool? {
        var stmt: OpaquePointer?
        guard
            prepare(
                "SELECT effect, remote_volume_id, remote_link_id, generation FROM remote_operation WHERE source_kind=? AND source_id=?;",
                &stmt)
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindKey(stmt, key)
        switch sqlite3_step(stmt) {
        case SQLITE_DONE: return true
        case SQLITE_ROW:
            guard let storedEffect = columnText(stmt, 0, roundTrip: true).flatMap(PendingSourceEffect.init(rawValue:)),
                storedEffect != .queueSync,
                columnText(stmt, 1, roundTrip: true) != nil,
                let storedLink = columnText(stmt, 2, roundTrip: true),
                sqlite3_column_type(stmt, 3) == SQLITE_INTEGER
            else { return nil }
            return storedEffect == effect && storedLink == linkID && sqlite3_column_int64(stmt, 3) == generation
        default:
            connection.markFailed(resultCode: sqlite3_extended_errcode(db))
            return nil
        }
    }

    /// Deletes the row of an included source once it owes nothing: no queue sync, no remote trash or restore, and no
    /// remote operation in flight. A row with any open effect stays.
    private func deleteSettledIncludedLocked(_ key: PendingSourceKey) -> Bool {
        execute(
            """
            DELETE FROM source_state
            WHERE source_kind=? AND source_id=? AND desired='included' AND remote_op IS NULL
              AND needs_queue_sync=0 AND needs_remote_trash=0 AND needs_remote_restore=0;
            """
        ) { bindKey($0, key) }
    }

    private func clearOperationBinding(for key: PendingSourceKey) -> Bool {
        execute("DELETE FROM remote_operation WHERE source_kind=? AND source_id=?;") { bindKey($0, key) }
    }

    /// Schedules the next attempt of a failed effect with the shared backoff.
    /// If a generation is supplied and it does not match the row, the write belongs to an obsolete
    /// decision; return true without updating the row so the pending write is dropped.
    @discardableResult
    public func deferEffects(
        for key: PendingSourceKey, at date: Date, generation: Int64? = nil
    ) -> Bool {
        standaloneWrite(refusing: false) {
            guard case .readable(let current) = sourceStateLocked(key) else { return false }
            guard let state = current else { return true }
            if let generation = generation, state.generation != generation { return true }
            let next = date.addingTimeInterval(PendingRetrySchedule.delay(afterAttempts: state.attempts))
            return execute(
                "UPDATE source_state SET attempts=attempts+1, next_attempt_at=?, updated_at=? WHERE source_kind=? AND source_id=?;"
            ) { stmt in
                sqlite3_bind_double(stmt, 1, next.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 2, date.timeIntervalSince1970)
                bindKey(stmt, key, from: 3)
            }
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
                    // A row that this build cannot read stays as it is and the other rows go on; a failed read fails
                    // the write (#982).
                    let read = sourceStatesLocked(where: "source_kind=? AND source_id=?") { self.bindKey($0, key) }
                    guard read.queried else { return false }
                    guard read.succeeded, !read.states.isEmpty else { return true }
                    return execute(
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

    /// A recheck can retire only the included decision and photo that it actually checked.
    /// Waiting preserves both the provenance and the obligation, without consuming an effect attempt.
    @discardableResult
    public func finishRestoreRecheck(
        _ checked: PendingSourceState, outcome: PendingBackupReturnOutcome, at date: Date, retryNotBefore: Date? = nil
    ) -> Bool {
        connection.withLock {
            transaction {
                guard case .readable(let current) = sourceStateLocked(checked.key) else { return false }
                guard let current, current.desired == .included, current.needsQueueSync,
                    current.generation == checked.generation, current.remote == checked.remote
                else { return true }
                let assignment: String
                let next: Date
                switch outcome {
                case .completed:
                    assignment = "needs_queue_sync=0, remote_op=NULL, attempts=0"
                    next = date
                case .remoteTrashed:
                    assignment = "remote_trashed=1, needs_remote_restore=1"
                    next = max(date, retryNotBefore ?? date)
                case .waiting(let until):
                    assignment = "needs_queue_sync=1"
                    next = max(date.addingTimeInterval(1), until)
                case .unreadable:
                    assignment = "needs_queue_sync=1"
                    next = max(date.addingTimeInterval(60), retryNotBefore ?? date)
                }
                guard
                    execute(
                        "UPDATE source_state SET \(assignment), next_attempt_at=?, updated_at=? WHERE source_kind=? AND source_id=?;",
                        bind: { stmt in
                            sqlite3_bind_double(stmt, 1, next.timeIntervalSince1970)
                            sqlite3_bind_double(stmt, 2, date.timeIntervalSince1970)
                            bindKey(stmt, checked.key, from: 3)
                        })
                else { return false }
                guard outcome == .completed else { return true }
                guard clearOperationBinding(for: checked.key) else { return false }
                return deleteSettledIncludedLocked(checked.key)
            }
        }
    }

    /// Stores the desired favorite state of a pending source. A later toggle replaces it.
    @discardableResult
    public func setFavoriteIntent(_ key: PendingSourceKey, favorite: Bool, at date: Date) -> Bool {
        standaloneWrite(refusing: false) {
            upsertActionLocked(key, kind: .favorite, albumID: "", desired: favorite, at: date)
        }
    }

    @discardableResult
    public func addAlbumIntent(_ key: PendingSourceKey, albumID: String, at date: Date) -> Bool {
        standaloneWrite(refusing: false) {
            upsertActionLocked(key, kind: .addToAlbum, albumID: albumID, desired: true, at: date)
        }
    }

    /// The rows that decode. Use `actionsRead()` where a missing row must not count as "nothing owed".
    public func actions() -> [PendingAction] {
        actionsRead().actions
    }

    /// Every action row that decodes, and whether the query succeeded and every row decoded.
    public func actionsRead() -> PendingActionsRead {
        connection.withLock { actionsLocked(where: nil) }
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
        standaloneWrite(refusing: false) {
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
        standaloneWrite(refusing: false) {
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
        standaloneWrite(refusing: false) {
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
        standaloneWrite(refusing: false) {
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

    /// The handoff of `revision`, or `unreadable` when its query failed or its row does not decode.
    private func handoffReadLocked(_ key: PendingSourceKey, revision: UploadBackupRevision) -> PendingHandoffRead {
        let read = handoffsReadLocked(where: "source_kind=? AND source_id=? AND revision_us=?") { stmt in
            self.bindKey(stmt, key)
            sqlite3_bind_int64(stmt, 3, revision.rawValue)
        }
        return read.complete ? .readable(read.handoffs.first) : .unreadable
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
    ) -> (states: [PendingSourceState], succeeded: Bool, queried: Bool) {
        var result: [PendingSourceState] = []
        var decoded = true
        let sql =
            "SELECT \(Self.sourceStateColumns) FROM source_state"
            + (condition.map { " WHERE \($0)" } ?? "") + " ORDER BY source_kind, source_id;"
        let queried = query(sql, bind: bind) { stmt in
            let remoteOperationIsNull = sqlite3_column_type(stmt, 20) == SQLITE_NULL
            let remoteOperation = columnText(stmt, 20, roundTrip: true).flatMap(PendingSourceEffect.init(rawValue:))
            guard let kind = columnText(stmt, 0, roundTrip: true).flatMap(UploadSourceIdentity.Kind.init(rawValue:)),
                let identifier = columnText(stmt, 1),
                let desired = columnText(stmt, 2, roundTrip: true).flatMap(PendingDesiredState.init(rawValue:)),
                remoteOperationIsNull || remoteOperation != nil
            else {
                Self.noteUndecodableRow()
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
        return (result, queried && decoded, queried)
    }

    /// A row that this build cannot decode, for example one that a newer build wrote. The row stays unchanged, its
    /// read reports it as incomplete, and the other rows keep working (#982).
    private static func noteUndecodableRow() {
        PhotoDiagnostics.shared.increment("pending.undecodableRow")
    }

    private func handoffsLocked(where condition: String, bind: ((OpaquePointer?) -> Void)? = nil) -> [PendingHandoff] {
        handoffsReadLocked(where: condition, bind: bind).handoffs
    }

    private func handoffsReadLocked(
        where condition: String, bind: ((OpaquePointer?) -> Void)? = nil
    ) -> (handoffs: [PendingHandoff], complete: Bool) {
        var result: [PendingHandoff] = []
        var decoded = true
        let queried = query(
            """
            SELECT source_kind, source_id, revision_us, remote_volume_id, remote_link_id, kind, created_at, acknowledged
            FROM handoff WHERE \(condition) ORDER BY created_at;
            """,
            bind: bind
        ) { stmt in
            if let handoff = handoffRow(stmt) {
                result.append(handoff)
            } else {
                decoded = false
                Self.noteUndecodableRow()
            }
        }
        return (result, queried && decoded)
    }

    private func handoffRow(_ stmt: OpaquePointer?) -> PendingHandoff? {
        guard let key = key(stmt, kindColumn: 0, idColumn: 1, roundTrip: true),
            let volume = columnText(stmt, 3, roundTrip: true),
            let link = columnText(stmt, 4, roundTrip: true),
            let kind = columnText(stmt, 5, roundTrip: true).flatMap(PendingHandoffKind.init(rawValue:))
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
            // A NULL album_id keeps its empty fallback; a stored value that does not round-trip makes the row unreadable.
            let albumID = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? "" : columnText(stmt, 3, roundTrip: true)
            guard let key = key(stmt, kindColumn: 0, idColumn: 1, roundTrip: true),
                let kind = columnText(stmt, 2, roundTrip: true).flatMap(PendingActionKind.init(rawValue:)),
                let albumID = albumID
            else {
                Self.noteUndecodableRow()
                decoded = false
                return
            }
            result.append(
                PendingAction(
                    key: key,
                    kind: kind,
                    albumID: albumID,
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

    /// A standalone write must commit itself, never join a transaction that a failed rollback left open. A lasting
    /// failure refuses it; a transient failure still permits another attempt. Closed handles use the statement checks.
    private func standaloneWrite<Result>(refusing failure: Result, _ body: () -> Result) -> Result {
        connection.withLock {
            if let db, sqlite3_get_autocommit(db) == 0 { return failure }
            guard !connection.operationFailed || connection.failuresAreTransient else { return failure }
            return body()
        }
    }

    /// Runs `body` in one IMMEDIATE transaction. Returns false and rolls back when `body` or the commit fails. A failed
    /// SQLite call in `body` records its own failure; a writer that refuses a row it cannot read records none (#982).
    private func transaction(_ body: () -> Bool) -> Bool {
        guard db != nil else {
            connection.markFailed()
            return false
        }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            connection.markFailed(resultCode: sqlite3_extended_errcode(db))
            return false
        }
        guard body() else {
            connection.rollBack()
            return false
        }
        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            let commit = sqlite3_extended_errcode(db)
            connection.rollBack()
            connection.markFailed(resultCode: commit)
            return false
        }
        return true
    }

    private func prepare(_ sql: String, _ stmt: inout OpaquePointer?) -> Bool {
        guard db != nil else {
            connection.markFailed()
            return false
        }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            // The extended code tells damaged data from a passing I/O error; read it before finalize resets it.
            let code = sqlite3_extended_errcode(db)
            sqlite3_finalize(stmt)
            stmt = nil
            connection.markFailed(resultCode: code)
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
            connection.markFailed(resultCode: sqlite3_extended_errcode(db))
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
            connection.markFailed(resultCode: sqlite3_extended_errcode(db))
            return false
        }
        return true
    }

    private func key(
        _ stmt: OpaquePointer?, kindColumn: Int32, idColumn: Int32, roundTrip: Bool = false
    ) -> PendingSourceKey? {
        guard
            let kind = columnText(stmt, kindColumn, roundTrip: roundTrip).flatMap(
                UploadSourceIdentity.Kind.init(rawValue:)),
            let identifier = columnText(stmt, idColumn, roundTrip: roundTrip)
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

    /// Reads a text column. With `roundTrip`, reads the full bytes of the column: the writers bind with a C string,
    /// so a stored value with an embedded NUL or bytes that are not strict UTF-8 cannot have come from this store
    /// (#1006).
    private func columnText(_ stmt: OpaquePointer?, _ index: Int32, roundTrip: Bool = false) -> String? {
        guard let text = sqlite3_column_text(stmt, index) else { return nil }
        guard roundTrip else { return String(cString: text) }
        return roundTrippedText(text, byteCount: sqlite3_column_bytes(stmt, index))
    }

    private func roundTrippedText(_ text: UnsafePointer<UInt8>, byteCount: Int32) -> String? {
        guard
            let value = String(
                bytes: UnsafeBufferPointer(start: text, count: Int(byteCount)), encoding: .utf8)
        else { return nil }
        return value.contains("\0") ? nil : value
    }

    // MARK: - Schema

    private static let legacySchema = """
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

    private static let operationSchema = """
        CREATE TABLE IF NOT EXISTS remote_operation(
          source_kind      TEXT NOT NULL,
          source_id        TEXT NOT NULL,
          effect           TEXT NOT NULL,
          remote_volume_id TEXT NOT NULL,
          remote_link_id   TEXT NOT NULL,
          generation       INTEGER NOT NULL,
          PRIMARY KEY(source_kind, source_id)
        );
        """

    private static var schema: String { legacySchema + "\n" + operationSchema }

    private static func openOnce(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        if let current = SQLiteStoreSchemaGate.openCurrentStore(
            at: url, schemaSQL: schema, policy: policy, strictEmptySchema: true,
            verifyVersion: { verifyVersion($0, expected: schemaVersion) }, stampVersion: stampVersion)
        {
            return current
        }
        // The fallback opens only a proven v1, never an unknown file or an empty store after a failed create.
        guard
            let legacy = SQLiteStoreSchemaGate.openCurrentStore(
                at: url, schemaSQL: legacySchema, policy: policy, strictEmptySchema: true,
                verifyVersion: { verifyVersion($0, expected: 1) }, stampVersion: { _ in false })
        else { return nil }
        return openMigratedLegacyStore(legacy)
    }

    /// Takes ownership of a verified legacy handle. A failed migration never exposes a v1 handle as v2.
    static func openMigratedLegacyStore(_ handle: OpaquePointer) -> OpaquePointer? {
        guard migrateLegacyStore(handle) else {
            sqlite3_close(handle)
            return nil
        }
        return handle
    }

    /// The locked recheck, table and version commit together. A refused statement or a crash leaves v1 intact.
    static func migrateLegacyStore(_ handle: OpaquePointer) -> Bool {
        return SQLiteStoreSchemaGate.withDurableCommits(handle) {
            guard sqlite3_exec(handle, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
            var committed = false
            defer { if !committed { sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil) } }
            guard verifyVersion(handle, expected: 1),
                SQLiteStoreSchemaGate.matchesCurrentSchema(handle, schemaSQL: legacySchema),
                sqlite3_exec(handle, operationSchema, nil, nil, nil) == SQLITE_OK,
                stampVersion(handle),
                SQLiteStoreSchemaGate.matchesCurrentSchema(handle, schemaSQL: schema),
                sqlite3_exec(handle, "COMMIT;", nil, nil, nil) == SQLITE_OK
            else { return false }
            committed = true
            return true
        } ?? false
    }

    private static func verifyVersion(_ handle: OpaquePointer?, expected: Int) -> Bool {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(handle, "SELECT value FROM pending_info WHERE key='schema';", -1, &stmt, nil)
                == SQLITE_OK
        else { return false }
        var onDisk: Int64?
        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW, sqlite3_column_type(stmt, 0) == SQLITE_INTEGER {
            onDisk = sqlite3_column_int64(stmt, 0)
        }
        sqlite3_finalize(stmt)
        return result == SQLITE_ROW && onDisk == Int64(expected)
            && hasSupportedObjectInventory(handle, version: expected)
    }

    /// V1 has six tables and eight indexes; v2 adds one table and its primary-key index. The shared matcher
    /// excludes SQLite names. Count every schema row here, allowing only the exact optional optimizer table.
    static func hasSupportedObjectInventory(_ handle: OpaquePointer?, version: Int) -> Bool {
        let count = version == 1 ? 14 : 16
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                handle,
                "SELECT COUNT(*) = \(count) + COALESCE(SUM((type,name,tbl_name,sql) = "
                    + "('table','sqlite_stat1','sqlite_stat1','CREATE TABLE sqlite_stat1(tbl,idx,stat)')), 0) FROM sqlite_schema;",
                -1, &stmt, nil) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int(stmt, 0) == 1
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
