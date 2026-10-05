import Foundation
import PhotosCore
import SQLite3

/// App-owned SQLite manifest of upload identities (`upload-manifest-v1.sqlite`): the persistence
/// behind "don't rehash unchanged files" and "remember known duplicates across runs". Lives next
/// to `library-v1.sqlite` in the per-account directory, so sign-out purge covers it wholesale
/// (`LibraryDatabaseLocation.purgeAccountData` removes the directory).
///
/// Same platform posture as `TimelineMetadataStore`: raw system SQLite (WAL), platform tuning
/// injected via `LibraryDatabasePolicy`, and fail-closed preservation when the on-disk schema is
/// incompatible. The manifest also owns upload receipts and remote checkpoints, so it is not a
/// disposable derived-data store.
///
/// Stores names, sizes, dates and hex hashes - never file contents. Thread-safe via an internal
/// lock: the upload queue hits it from concurrent per-item tasks.
public final class UploadIdentityManifestStore: UploadIdentityStore, UploadRemoteContentIndexStore, @unchecked Sendable
{
    public static let databaseFileName = "upload-manifest-v1.sqlite"

    /// Persisted `outcome` values. Raw strings (not the decision enum) so the schema never has to
    /// change when decision cases evolve; unknown values are treated as "no decision".
    public enum Outcome: String, Sendable {
        /// We uploaded this resource ourselves; `remote_vol`/`remote_link` identify the node.
        case uploaded
        /// The server reported an active duplicate for this exact identity.
        case duplicateActive
        /// The server reported the identity as trashed - skipped, user deleted it intentionally.
        case duplicateTrashed
    }

    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let schemaVersion = 8

    public init?(url: URL, policy: LibraryDatabasePolicy = .conservative) {
        guard let handle = Self.openVerified(url: url, policy: policy) else { return nil }
        db = handle
    }

    deinit { close() }

    public func close() {
        lock.withLock {
            guard db != nil else { return }
            sqlite3_exec(db, "PRAGMA optimize;", nil, nil, nil)
            sqlite3_close(db)
            db = nil
        }
    }

    // MARK: Open / schema

    private static func openVerified(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        let schema = """
            CREATE TABLE IF NOT EXISTS manifest_info(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS upload_identity(
              source_kind   TEXT NOT NULL,
              source_id     TEXT NOT NULL,
              resource      TEXT NOT NULL,
              filename      TEXT NOT NULL,
              corrected     TEXT NOT NULL,
              size          INTEGER NOT NULL,
              mtime         REAL NOT NULL,
              sha1_hex      TEXT NOT NULL,
              name_hash     TEXT NOT NULL,
              content_hash  TEXT NOT NULL,
              key_epoch     TEXT NOT NULL,
              remote_vol    TEXT,
              remote_link   TEXT,
              outcome       TEXT,
              updated_at    REAL NOT NULL,
              PRIMARY KEY (source_kind, source_id, resource)
            );
            CREATE INDEX IF NOT EXISTS upload_identity_content_idx
              ON upload_identity(content_hash, key_epoch);
            CREATE TABLE IF NOT EXISTS remote_content_index(
              key_epoch     TEXT NOT NULL,
              content_hash  TEXT NOT NULL,
              remote_link   TEXT NOT NULL,
              PRIMARY KEY (key_epoch, content_hash, remote_link)
            );
            CREATE INDEX IF NOT EXISTS remote_content_index_lookup_idx
              ON remote_content_index(key_epoch, content_hash);
            CREATE TABLE IF NOT EXISTS remote_content_unresolved(
              key_epoch     TEXT NOT NULL,
              remote_link   TEXT NOT NULL,
              reason        TEXT NOT NULL DEFAULT 'missingContentHash',
              first_observed REAL NOT NULL DEFAULT 0,
              last_observed REAL NOT NULL DEFAULT 0,
              last_repair   REAL,
              generation    TEXT NOT NULL,
              PRIMARY KEY (key_epoch, remote_link)
            );
            CREATE TABLE IF NOT EXISTS remote_content_index_checkpoint(
              key_epoch     TEXT PRIMARY KEY,
              event_id      TEXT NOT NULL,
              refreshed_at  REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS remote_asset_index(
              key_epoch      TEXT NOT NULL,
              external_id    TEXT NOT NULL,
              revision_us    INTEGER NOT NULL,
              resource_count INTEGER NOT NULL,
              primary_link   TEXT NOT NULL,
              PRIMARY KEY (key_epoch, external_id, revision_us)
            );
            CREATE INDEX IF NOT EXISTS remote_asset_index_lookup_idx
              ON remote_asset_index(key_epoch, external_id, revision_us);
            CREATE TABLE IF NOT EXISTS remote_asset_index_link(
              key_epoch   TEXT NOT NULL,
              external_id TEXT NOT NULL,
              revision_us INTEGER NOT NULL,
              remote_link TEXT NOT NULL,
              PRIMARY KEY (key_epoch, external_id, revision_us, remote_link)
            );
            CREATE INDEX IF NOT EXISTS remote_asset_index_link_lookup_idx
              ON remote_asset_index_link(key_epoch, remote_link);
            CREATE TABLE IF NOT EXISTS remote_asset_index_checkpoint(
              key_epoch    TEXT PRIMARY KEY,
              event_id     TEXT NOT NULL,
              refreshed_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS remote_content_build_checkpoint(
              key_epoch          TEXT PRIMARY KEY,
              build_id           TEXT NOT NULL,
              event_id           TEXT NOT NULL,
              source_fingerprint TEXT NOT NULL,
              cursor             INTEGER NOT NULL,
              total              INTEGER NOT NULL,
              updated_at         REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS remote_content_build_record(
              key_epoch    TEXT NOT NULL,
              content_hash TEXT NOT NULL,
              remote_link  TEXT NOT NULL,
              PRIMARY KEY (key_epoch, content_hash, remote_link)
            );
            CREATE TABLE IF NOT EXISTS remote_content_build_unresolved(
              key_epoch      TEXT NOT NULL,
              remote_link    TEXT NOT NULL,
              reason         TEXT NOT NULL DEFAULT 'missingContentHash',
              first_observed REAL NOT NULL DEFAULT 0,
              last_observed  REAL NOT NULL DEFAULT 0,
              last_repair    REAL,
              generation     TEXT NOT NULL,
              PRIMARY KEY (key_epoch, remote_link)
            );
            CREATE TABLE IF NOT EXISTS remote_content_build_external(
              key_epoch   TEXT NOT NULL,
              remote_link TEXT NOT NULL,
              external_id TEXT NOT NULL,
              revision_us INTEGER NOT NULL,
              PRIMARY KEY (key_epoch, remote_link)
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
            sqlite3_prepare_v2(handle, "SELECT value FROM manifest_info WHERE key='schema';", -1, &stmt, nil)
                == SQLITE_OK
        else {
            return false
        }
        let result = sqlite3_step(stmt)
        let onDisk = result == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : nil
        sqlite3_finalize(stmt)
        return result == SQLITE_ROW && onDisk == schemaVersion
    }

    private static func stampVersion(_ handle: OpaquePointer?) -> Bool {
        sqlite3_exec(
            handle,
            "INSERT INTO manifest_info(key, value) VALUES('schema', \(schemaVersion));",
            nil, nil, nil
        ) == SQLITE_OK
    }

    // MARK: UploadIdentityStore

    public func record(for source: UploadSourceIdentity) -> UploadIdentityRecord? {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    """
                    SELECT filename, corrected, size, mtime, sha1_hex, name_hash, content_hash,
                           key_epoch, remote_vol, remote_link, outcome, updated_at
                    FROM upload_identity WHERE source_kind=? AND source_id=? AND resource=?;
                    """,
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, source.kind.rawValue)
            bindText(stmt, 2, source.identifier)
            bindText(stmt, 3, source.resource.rawValue)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return UploadIdentityRecord(
                source: source,
                filename: columnText(stmt, 0) ?? "",
                correctedName: columnText(stmt, 1) ?? "",
                fileSize: sqlite3_column_int64(stmt, 2),
                modificationDate: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                sha1Hex: columnText(stmt, 4) ?? "",
                nameHash: columnText(stmt, 5) ?? "",
                contentHash: columnText(stmt, 6) ?? "",
                hashKeyEpoch: columnText(stmt, 7) ?? "",
                remoteVolumeID: columnText(stmt, 8),
                remoteLinkID: columnText(stmt, 9),
                outcome: columnText(stmt, 10),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
            )
        }
    }

    public func trustedRecords(contentHash: String, hashKeyEpoch: String, limit: Int) -> [UploadIdentityRecord] {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    """
                    SELECT source_kind, source_id, resource, filename, corrected, size, mtime,
                           sha1_hex, name_hash, remote_vol, remote_link, outcome, updated_at
                    FROM upload_identity
                    WHERE content_hash=? AND key_epoch=?
                      AND remote_link IS NOT NULL
                      AND outcome IN ('uploaded', 'duplicateActive')
                    LIMIT ?;
                    """,
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, contentHash)
            bindText(stmt, 2, hashKeyEpoch)
            sqlite3_bind_int64(stmt, 3, Int64(max(0, limit)))
            var records: [UploadIdentityRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let kindRaw = columnText(stmt, 0),
                    let kind = UploadSourceIdentity.Kind(rawValue: kindRaw),
                    let identifier = columnText(stmt, 1),
                    let resourceRaw = columnText(stmt, 2)
                else { continue }
                let resource = UploadSourceIdentity.Resource(rawValue: resourceRaw)
                records.append(
                    UploadIdentityRecord(
                        source: UploadSourceIdentity(kind: kind, identifier: identifier, resource: resource),
                        filename: columnText(stmt, 3) ?? "",
                        correctedName: columnText(stmt, 4) ?? "",
                        fileSize: sqlite3_column_int64(stmt, 5),
                        modificationDate: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                        sha1Hex: columnText(stmt, 7) ?? "",
                        nameHash: columnText(stmt, 8) ?? "",
                        contentHash: contentHash,
                        hashKeyEpoch: hashKeyEpoch,
                        remoteVolumeID: columnText(stmt, 9),
                        remoteLinkID: columnText(stmt, 10),
                        outcome: columnText(stmt, 11),
                        updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))
                    ))
            }
            return records
        }
    }

    /// Scans without an index: the schema gate forbids a new one, and only a replacement after an edit and the merge
    /// of exact duplicates read this.
    public func sources(withRemoteLinkID linkID: String) -> [UploadSourceIdentity]? {
        sources(withRemoteLinkIDs: [linkID])?[linkID]
    }

    /// One scan for all links: without an index on `remote_link`, each single lookup would scan the table again.
    public func sources(withRemoteLinkIDs linkIDs: Set<String>) -> [String: [UploadSourceIdentity]]? {
        guard !linkIDs.isEmpty else { return [:] }
        return lock.withLock {
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    """
                    SELECT remote_link, source_kind, source_id, resource FROM upload_identity
                    WHERE remote_link IS NOT NULL AND outcome IN ('uploaded', 'duplicateActive');
                    """,
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            var sourcesByLink = Dictionary(uniqueKeysWithValues: linkIDs.map { ($0, [UploadSourceIdentity]()) })
            while true {
                switch sqlite3_step(stmt) {
                case SQLITE_ROW:
                    guard let linkID = columnText(stmt, 0), linkIDs.contains(linkID) else { continue }
                    guard let kindRaw = columnText(stmt, 1), let kind = UploadSourceIdentity.Kind(rawValue: kindRaw),
                        let identifier = columnText(stmt, 2)
                    else { return nil }
                    sourcesByLink[linkID, default: []].append(
                        UploadSourceIdentity(
                            kind: kind, identifier: identifier,
                            resource: UploadSourceIdentity.Resource(rawValue: columnText(stmt, 3) ?? "")))
                case SQLITE_DONE:
                    return sourcesByLink
                default:
                    return nil
                }
            }
        }
    }

    @discardableResult
    public func forgetRemoteLinks(_ linkIDs: Set<String>, of source: UploadSourceIdentity) -> Bool {
        let unique = linkIDs.filter { !$0.isEmpty }
        guard !unique.isEmpty else { return true }
        return lock.withLock {
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    """
                    UPDATE upload_identity SET remote_vol=NULL, remote_link=NULL, outcome=NULL
                    WHERE remote_link=? AND source_kind=? AND source_id=?;
                    """,
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return false }
            defer { sqlite3_finalize(stmt) }
            for linkID in unique.sorted() {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, linkID)
                bindText(stmt, 2, source.kind.rawValue)
                bindText(stmt, 3, source.identifier)
                guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            }
            return true
        }
    }

    @discardableResult
    public func upsert(_ record: UploadIdentityRecord) -> Bool {
        write(record, keepingRemoteLinkChangedFrom: nil, onlyIfUnchanged: false)
    }

    /// One statement, so a merge that moves the row between the comparison and the write cannot slip in.
    @discardableResult
    public func upsert(_ record: UploadIdentityRecord, keepingRemoteLinkChangedFrom readLinkID: String?) -> Bool {
        write(record, keepingRemoteLinkChangedFrom: readLinkID, onlyIfUnchanged: true)
    }

    private func write(
        _ record: UploadIdentityRecord, keepingRemoteLinkChangedFrom readLinkID: String?, onlyIfUnchanged: Bool
    ) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    """
                    INSERT INTO upload_identity(
                      source_kind, source_id, resource, filename, corrected, size, mtime,
                      sha1_hex, name_hash, content_hash, key_epoch, remote_vol, remote_link,
                      outcome, updated_at
                    ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(source_kind, source_id, resource) DO UPDATE SET
                      filename=excluded.filename, corrected=excluded.corrected, size=excluded.size,
                      mtime=excluded.mtime, sha1_hex=excluded.sha1_hex, name_hash=excluded.name_hash,
                      content_hash=excluded.content_hash, key_epoch=excluded.key_epoch,
                      remote_vol=CASE WHEN ?16 = 0 OR remote_link IS ?17
                        THEN excluded.remote_vol ELSE remote_vol END,
                      outcome=CASE WHEN ?16 = 0 OR remote_link IS ?17 THEN excluded.outcome ELSE outcome END,
                      remote_link=CASE WHEN ?16 = 0 OR remote_link IS ?17
                        THEN excluded.remote_link ELSE remote_link END,
                      updated_at=excluded.updated_at;
                    """,
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, record.source.kind.rawValue)
            bindText(stmt, 2, record.source.identifier)
            bindText(stmt, 3, record.source.resource.rawValue)
            bindText(stmt, 4, record.filename)
            bindText(stmt, 5, record.correctedName)
            sqlite3_bind_int64(stmt, 6, record.fileSize)
            sqlite3_bind_double(stmt, 7, record.modificationDate.timeIntervalSince1970)
            bindText(stmt, 8, record.sha1Hex)
            bindText(stmt, 9, record.nameHash)
            bindText(stmt, 10, record.contentHash)
            bindText(stmt, 11, record.hashKeyEpoch)
            bindOptionalText(stmt, 12, record.remoteVolumeID)
            bindOptionalText(stmt, 13, record.remoteLinkID)
            bindOptionalText(stmt, 14, record.outcome)
            sqlite3_bind_double(stmt, 15, record.updatedAt.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 16, onlyIfUnchanged ? 1 : 0)
            bindOptionalText(stmt, 17, readLinkID)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    /// One transaction, so a crash moves every row or none.
    @discardableResult
    public func rebindRemoteLinks(_ moves: [UploadRemoteLinkMove], hashKeyEpoch: String) -> Bool {
        let valid = moves.filter { !$0.from.isEmpty && !$0.to.isEmpty && $0.from != $0.to }
        guard !valid.isEmpty else { return true }
        let now = Date().timeIntervalSince1970
        return lock.withLock {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
            var stmt: OpaquePointer?
            var didWrite =
                sqlite3_prepare_v2(
                    db,
                    """
                    UPDATE upload_identity SET remote_link=?, outcome='duplicateActive', updated_at=?
                    WHERE remote_link=? AND content_hash=? AND key_epoch=?
                      AND outcome IN ('uploaded', 'duplicateActive');
                    """,
                    -1, &stmt, nil
                ) == SQLITE_OK
            for move in valid where didWrite {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, move.to)
                sqlite3_bind_double(stmt, 2, now)
                bindText(stmt, 3, move.from)
                bindText(stmt, 4, move.contentHash)
                bindText(stmt, 5, hashKeyEpoch)
                didWrite = sqlite3_step(stmt) == SQLITE_DONE
            }
            sqlite3_finalize(stmt)
            guard didWrite, sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    // MARK: UploadRemoteContentIndexStore

    public func remoteContentRecords(
        contentHash: String,
        hashKeyEpoch: String,
        limit: Int
    ) -> [UploadRemoteContentIndexRecord] {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    "SELECT remote_link FROM remote_content_index WHERE key_epoch=? AND content_hash=? LIMIT ?;",
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, hashKeyEpoch)
            bindText(stmt, 2, contentHash)
            sqlite3_bind_int64(stmt, 3, Int64(max(0, limit)))
            var records: [UploadRemoteContentIndexRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let remoteLinkID = columnText(stmt, 0) else { continue }
                records.append(
                    UploadRemoteContentIndexRecord(
                        contentHash: contentHash,
                        hashKeyEpoch: hashKeyEpoch,
                        remoteLinkID: remoteLinkID
                    ))
            }
            return records
        }
    }

    public func remoteContentIndexCheckpoint(
        hashKeyEpoch: String
    ) -> UploadRemoteContentIndexCheckpoint? {
        lock.withLock { readRemoteContentCheckpointLocked(hashKeyEpoch: hashKeyEpoch) }
    }

    public func hasRemoteAssetIndexCheckpoint(hashKeyEpoch: String) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    "SELECT 1 FROM remote_asset_index_checkpoint WHERE key_epoch=? LIMIT 1;",
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, hashKeyEpoch)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    public func remoteAssetRecords(
        for identities: [UploadBackupExternalIdentity],
        hashKeyEpoch: String
    ) -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
        guard !identities.isEmpty else { return [:] }
        return lock.withLock {
            var recordStmt: OpaquePointer?
            var linksStmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    """
                    SELECT resource_count, primary_link FROM remote_asset_index
                    WHERE key_epoch=? AND external_id=? AND revision_us=?;
                    """,
                    -1, &recordStmt, nil
                ) == SQLITE_OK,
                sqlite3_prepare_v2(
                    db,
                    """
                    SELECT remote_link FROM remote_asset_index_link
                    WHERE key_epoch=? AND external_id=? AND revision_us=? ORDER BY remote_link;
                    """,
                    -1, &linksStmt, nil
                ) == SQLITE_OK
            else {
                sqlite3_finalize(recordStmt)
                sqlite3_finalize(linksStmt)
                return [:]
            }
            defer {
                sqlite3_finalize(recordStmt)
                sqlite3_finalize(linksStmt)
            }

            var result: [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] = [:]
            result.reserveCapacity(identities.count)
            for identity in Set(identities) {
                sqlite3_reset(recordStmt)
                sqlite3_clear_bindings(recordStmt)
                bindText(recordStmt, 1, hashKeyEpoch)
                bindText(recordStmt, 2, identity.identifier)
                sqlite3_bind_int64(recordStmt, 3, identity.revision.rawValue)
                guard sqlite3_step(recordStmt) == SQLITE_ROW else { continue }
                let resourceCount = Int(sqlite3_column_int(recordStmt, 0))
                guard let primaryLink = columnText(recordStmt, 1) else { continue }

                sqlite3_reset(linksStmt)
                sqlite3_clear_bindings(linksStmt)
                bindText(linksStmt, 1, hashKeyEpoch)
                bindText(linksStmt, 2, identity.identifier)
                sqlite3_bind_int64(linksStmt, 3, identity.revision.rawValue)
                var links: [String] = []
                while sqlite3_step(linksStmt) == SQLITE_ROW {
                    if let link = columnText(linksStmt, 0) { links.append(link) }
                }
                guard links.count == resourceCount, links.contains(primaryLink) else { continue }
                links.removeAll { $0 == primaryLink }
                links.insert(primaryLink, at: 0)
                result[identity] = UploadRemoteAssetIndexRecord(
                    externalIdentity: identity,
                    resourceCount: resourceCount,
                    remoteLinkIDs: links,
                    hashKeyEpoch: hashKeyEpoch
                )
            }
            return result
        }
    }

    public func remoteContentIndexHealth(hashKeyEpoch: String) -> UploadRemoteContentIndexHealth {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    """
                    SELECT
                      (SELECT COUNT(*) FROM remote_content_index WHERE key_epoch=?),
                      (SELECT COUNT(*) FROM remote_content_unresolved WHERE key_epoch=?);
                    """,
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return .unavailable }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, hashKeyEpoch)
            bindText(stmt, 2, hashKeyEpoch)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return .unavailable }
            let indexed = Int(sqlite3_column_int64(stmt, 0))
            let unresolved = Int(sqlite3_column_int64(stmt, 1))
            return unresolved > 0
                ? .degraded(indexedCount: indexed, unresolvedCount: unresolved)
                : .complete(indexedCount: indexed)
        }
    }

    public func remoteContentIndexBuildCheckpoint(
        hashKeyEpoch: String
    ) -> UploadRemoteContentIndexBuildCheckpoint? {
        lock.withLock { readBuildCheckpointLocked(hashKeyEpoch: hashKeyEpoch) }
    }

    public func beginRemoteContentIndexBuild(
        hashKeyEpoch: String,
        eventID: String,
        sourceFingerprint: String,
        total: Int,
        updatedAt: Date
    ) -> UploadRemoteContentIndexBuildCheckpoint? {
        guard !hashKeyEpoch.isEmpty, !eventID.isEmpty, !sourceFingerprint.isEmpty, total >= 0 else {
            return nil
        }
        return lock.withLock {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return nil }
            if let existing = readBuildCheckpointLocked(hashKeyEpoch: hashKeyEpoch),
                existing.eventID == eventID,
                existing.sourceFingerprint == sourceFingerprint,
                existing.total == total,
                existing.cursor <= total
            {
                guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    return nil
                }
                return existing
            }
            guard clearRemoteContentBuildLocked(hashKeyEpoch: hashKeyEpoch) else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return nil
            }
            let buildID = UUID().uuidString
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO remote_content_build_checkpoint(key_epoch,build_id,event_id,source_fingerprint,cursor,total,updated_at) VALUES(?,?,?,?,0,?,?);",
                    -1, &stmt, nil
                ) == SQLITE_OK
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return nil
            }
            bindText(stmt, 1, hashKeyEpoch)
            bindText(stmt, 2, buildID)
            bindText(stmt, 3, eventID)
            bindText(stmt, 4, sourceFingerprint)
            sqlite3_bind_int64(stmt, 5, Int64(total))
            sqlite3_bind_double(stmt, 6, updatedAt.timeIntervalSince1970)
            let wrote = sqlite3_step(stmt) == SQLITE_DONE
            sqlite3_finalize(stmt)
            guard wrote, sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return nil
            }
            return UploadRemoteContentIndexBuildCheckpoint(
                buildID: buildID,
                eventID: eventID,
                sourceFingerprint: sourceFingerprint,
                cursor: 0,
                total: total,
                updatedAt: updatedAt
            )
        }
    }

    @discardableResult
    public func appendRemoteContentIndexBuild(
        records: [UploadRemoteContentIndexRecord],
        unresolvedIssues: [UploadRemoteContentIndexIssue],
        externalIdentities: [UploadRemoteExternalIdentityRecord],
        hashKeyEpoch: String,
        buildID: String,
        nextCursor: Int,
        updatedAt: Date
    ) -> Bool {
        guard !buildID.isEmpty,
            records.allSatisfy({ $0.hashKeyEpoch == hashKeyEpoch })
        else { return false }
        return lock.withLock {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
            guard let checkpoint = readBuildCheckpointLocked(hashKeyEpoch: hashKeyEpoch),
                checkpoint.buildID == buildID,
                nextCursor >= checkpoint.cursor, nextCursor <= checkpoint.total
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            let ok =
                writeBuildContentRecordsLocked(records)
                && writeBuildUnresolvedLocked(unresolvedIssues, hashKeyEpoch: hashKeyEpoch)
                && writeBuildExternalLocked(externalIdentities, hashKeyEpoch: hashKeyEpoch)
                && updateBuildCursorLocked(
                    hashKeyEpoch: hashKeyEpoch,
                    buildID: buildID,
                    nextCursor: nextCursor,
                    updatedAt: updatedAt
                )
            guard ok, sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    public func stagedRemoteExternalIdentities(
        hashKeyEpoch: String,
        buildID: String
    ) -> [String: UploadBackupExternalIdentity] {
        lock.withLock {
            guard sqlite3_exec(db, "BEGIN;", nil, nil, nil) == SQLITE_OK else { return [:] }
            guard readBuildCheckpointLocked(hashKeyEpoch: hashKeyEpoch)?.buildID == buildID else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return [:]
            }
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    "SELECT remote_link,external_id,revision_us FROM remote_content_build_external WHERE key_epoch=?;",
                    -1, &stmt, nil
                ) == SQLITE_OK
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return [:]
            }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, hashKeyEpoch)
            var result: [String: UploadBackupExternalIdentity] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let link = columnText(stmt, 0), let identifier = columnText(stmt, 1) else { continue }
                result[link] = UploadBackupExternalIdentity(
                    identifier: identifier,
                    revision: UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 2))
                )
            }
            guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return [:]
            }
            return result
        }
    }

    @discardableResult
    public func finishRemoteContentIndexBuild(
        remoteAssetRecords: [UploadRemoteAssetIndexRecord],
        hashKeyEpoch: String,
        buildID: String,
        checkpoint: UploadRemoteContentIndexCheckpoint
    ) -> Bool {
        guard !buildID.isEmpty,
            remoteAssetRecords.allSatisfy({ $0.hashKeyEpoch == hashKeyEpoch })
        else { return false }
        return lock.withLock {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
            guard let build = readBuildCheckpointLocked(hashKeyEpoch: hashKeyEpoch),
                build.buildID == buildID,
                build.eventID == checkpoint.eventID,
                build.cursor == build.total
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            let statements = ["DELETE FROM remote_content_index WHERE key_epoch=?;"]
            var ok = true
            for sql in statements where ok {
                var stmt: OpaquePointer?
                ok = sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
                if ok {
                    bindText(stmt, 1, hashKeyEpoch)
                    ok = sqlite3_step(stmt) == SQLITE_DONE
                }
                sqlite3_finalize(stmt)
            }
            if ok {
                let stagedIssues = readBuildRemoteIssuesLocked(hashKeyEpoch: hashKeyEpoch)
                ok =
                    stagedIssues != nil
                    && executeBoundLocked(
                        "INSERT INTO remote_content_index SELECT key_epoch,content_hash,remote_link FROM remote_content_build_record WHERE key_epoch=?;",
                        value: hashKeyEpoch
                    )
                    && deleteResolvedRemoteIssuesAfterBuildLocked(hashKeyEpoch: hashKeyEpoch)
                    && writeUnresolvedRemoteIssuesLocked(
                        stagedIssues ?? [],
                        hashKeyEpoch: hashKeyEpoch
                    )
            }
            ok =
                ok
                && deleteRemoteAssetEpochLocked(hashKeyEpoch: hashKeyEpoch)
                && writeRemoteAssetRecordsLocked(remoteAssetRecords)
                && writeRemoteContentCheckpointLocked(checkpoint, hashKeyEpoch: hashKeyEpoch)
                && writeRemoteAssetCheckpointLocked(checkpoint, hashKeyEpoch: hashKeyEpoch)
                && clearRemoteContentBuildLocked(hashKeyEpoch: hashKeyEpoch)
            guard ok, sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    @discardableResult
    public func invalidateRemoteContentIndexBuild(hashKeyEpoch: String) -> Bool {
        guard !hashKeyEpoch.isEmpty else { return false }
        return lock.withLock {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
            guard clearRemoteContentBuildLocked(hashKeyEpoch: hashKeyEpoch),
                sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    @discardableResult
    public func replaceRemoteContentIndex(
        _ records: [UploadRemoteContentIndexRecord],
        remoteAssetRecords: [UploadRemoteAssetIndexRecord] = [],
        unresolvedIssues: [UploadRemoteContentIndexIssue],
        hashKeyEpoch: String,
        checkpoint: UploadRemoteContentIndexCheckpoint
    ) -> Bool {
        guard records.allSatisfy({ $0.hashKeyEpoch == hashKeyEpoch }),
            remoteAssetRecords.allSatisfy({ $0.hashKeyEpoch == hashKeyEpoch })
        else { return false }
        return lock.withLock {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
            var deleteStmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    "DELETE FROM remote_content_index WHERE key_epoch=?;",
                    -1, &deleteStmt, nil
                ) == SQLITE_OK
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            bindText(deleteStmt, 1, hashKeyEpoch)
            let didDelete = sqlite3_step(deleteStmt) == SQLITE_DONE
            sqlite3_finalize(deleteStmt)

            var deleteUnresolved: OpaquePointer?
            guard didDelete,
                sqlite3_prepare_v2(
                    db,
                    "DELETE FROM remote_content_unresolved WHERE key_epoch=?;",
                    -1, &deleteUnresolved, nil
                ) == SQLITE_OK
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            bindText(deleteUnresolved, 1, hashKeyEpoch)
            let didDeleteUnresolved = sqlite3_step(deleteUnresolved) == SQLITE_DONE
            sqlite3_finalize(deleteUnresolved)

            let didWrite =
                didDeleteUnresolved
                && clearRemoteContentBuildLocked(hashKeyEpoch: hashKeyEpoch)
                && deleteRemoteAssetEpochLocked(hashKeyEpoch: hashKeyEpoch)
                && writeRemoteContentRecordsLocked(records)
                && writeRemoteAssetRecordsLocked(remoteAssetRecords)
                && writeUnresolvedRemoteIssuesLocked(
                    unresolvedIssues,
                    hashKeyEpoch: hashKeyEpoch
                )
                && writeRemoteContentCheckpointLocked(checkpoint, hashKeyEpoch: hashKeyEpoch)
                && writeRemoteAssetCheckpointLocked(checkpoint, hashKeyEpoch: hashKeyEpoch)
            guard didWrite, sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    @discardableResult
    public func applyRemoteContentIndexChanges(
        upserting records: [UploadRemoteContentIndexRecord],
        upsertingRemoteAssetRecords: [UploadRemoteAssetIndexRecord] = [],
        unresolvedIssues: [UploadRemoteContentIndexIssue],
        removingRemoteLinkIDs: [String],
        hashKeyEpoch: String,
        expectedEventID: String,
        checkpoint: UploadRemoteContentIndexCheckpoint
    ) -> Bool {
        guard records.allSatisfy({ $0.hashKeyEpoch == hashKeyEpoch }),
            upsertingRemoteAssetRecords.allSatisfy({ $0.hashKeyEpoch == hashKeyEpoch }),
            !expectedEventID.isEmpty
        else { return false }
        return lock.withLock {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
            guard readRemoteContentCheckpointLocked(hashKeyEpoch: hashKeyEpoch)?.eventID == expectedEventID else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            let didDelete =
                clearRemoteContentBuildLocked(hashKeyEpoch: hashKeyEpoch)
                && deleteRemoteContentLinksLocked(
                    removingRemoteLinkIDs,
                    hashKeyEpoch: hashKeyEpoch
                )
                && invalidateRemoteAssetRecordsLocked(
                    touching: removingRemoteLinkIDs,
                    hashKeyEpoch: hashKeyEpoch
                )
            let didWrite =
                didDelete
                && writeRemoteContentRecordsLocked(records)
                && writeRemoteAssetRecordsLocked(upsertingRemoteAssetRecords)
                && writeUnresolvedRemoteIssuesLocked(
                    unresolvedIssues,
                    hashKeyEpoch: hashKeyEpoch
                )
                && writeRemoteContentCheckpointLocked(checkpoint, hashKeyEpoch: hashKeyEpoch)
                && writeRemoteAssetCheckpointLocked(checkpoint, hashKeyEpoch: hashKeyEpoch)
            guard didWrite, sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    @discardableResult
    public func upsertRemoteContentRecord(_ record: UploadRemoteContentIndexRecord) -> Bool {
        lock.withLock {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
            let didDelete =
                clearRemoteContentBuildLocked(hashKeyEpoch: record.hashKeyEpoch)
                && deleteUnresolvedRemoteLinksLocked(
                    [record.remoteLinkID],
                    hashKeyEpoch: record.hashKeyEpoch
                )
            let didWrite = didDelete && writeRemoteContentRecordsLocked([record])
            guard didWrite, sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    public func remoteContentDuplicateGroups(hashKeyEpoch: String) -> [String: [String]]? {
        lock.withLock {
            var stmt: OpaquePointer?
            // A related file of a proven compound, such as a Live Photo video or the original of an edit, holds the
            // bytes of another photo but never is a main photo. Proton cannot detach it, so it is left out here,
            // before any request.
            guard
                sqlite3_prepare_v2(
                    db,
                    """
                    WITH related(remote_link) AS (
                      SELECT l.remote_link FROM remote_asset_index_link l
                      JOIN remote_asset_index a ON a.key_epoch=l.key_epoch AND a.external_id=l.external_id
                        AND a.revision_us=l.revision_us
                      WHERE l.key_epoch=?1 AND l.remote_link != a.primary_link
                    ),
                    candidates(content_hash, remote_link) AS (
                      SELECT content_hash, remote_link FROM remote_content_index
                      WHERE key_epoch=?1 AND remote_link NOT IN (SELECT remote_link FROM related)
                    )
                    SELECT content_hash, remote_link FROM candidates
                    WHERE content_hash IN (
                      SELECT content_hash FROM candidates
                      GROUP BY content_hash HAVING COUNT(DISTINCT remote_link) > 1
                    )
                    ORDER BY content_hash, remote_link;
                    """,
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, hashKeyEpoch)
            var groups: [String: [String]] = [:]
            while true {
                switch sqlite3_step(stmt) {
                case SQLITE_ROW:
                    guard let contentHash = columnText(stmt, 0), let linkID = columnText(stmt, 1) else { return nil }
                    groups[contentHash, default: []].append(linkID)
                case SQLITE_DONE:
                    return groups
                default:
                    return nil
                }
            }
        }
    }

    public func remoteContentDuplicateSizes(hashKeyEpoch: String) -> [String: Int64]? {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    """
                    WITH related(remote_link) AS (
                      SELECT l.remote_link FROM remote_asset_index_link l
                      JOIN remote_asset_index a ON a.key_epoch=l.key_epoch AND a.external_id=l.external_id
                        AND a.revision_us=l.revision_us
                      WHERE l.key_epoch=?1 AND l.remote_link != a.primary_link
                    )
                    SELECT content_hash, MAX(size) FROM upload_identity
                    WHERE key_epoch=?1 AND size > 0 AND content_hash IN (
                      SELECT content_hash FROM remote_content_index
                      WHERE key_epoch=?1 AND remote_link NOT IN (SELECT remote_link FROM related)
                      GROUP BY content_hash HAVING COUNT(DISTINCT remote_link) > 1
                    )
                    GROUP BY content_hash;
                    """,
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, hashKeyEpoch)
            var sizes: [String: Int64] = [:]
            while true {
                switch sqlite3_step(stmt) {
                case SQLITE_ROW:
                    guard let contentHash = columnText(stmt, 0) else { return nil }
                    sizes[contentHash] = sqlite3_column_int64(stmt, 1)
                case SQLITE_DONE:
                    return sizes
                default:
                    return nil
                }
            }
        }
    }

    /// Row count - surfaced for tests and a future cache-status UI.
    public func count() -> Int {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM upload_identity;", -1, &stmt, nil) == SQLITE_OK else {
                return 0
            }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    private func writeRemoteContentRecordsLocked(_ records: [UploadRemoteContentIndexRecord]) -> Bool {
        guard !records.isEmpty else { return true }
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                "INSERT OR REPLACE INTO remote_content_index(key_epoch, content_hash, remote_link) VALUES(?,?,?);",
                -1, &stmt, nil
            ) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        for record in records {
            guard !record.hashKeyEpoch.isEmpty, !record.contentHash.isEmpty, !record.remoteLinkID.isEmpty else {
                return false
            }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, record.hashKeyEpoch)
            bindText(stmt, 2, record.contentHash)
            bindText(stmt, 3, record.remoteLinkID)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return true
    }

    private func deleteRemoteAssetEpochLocked(hashKeyEpoch: String) -> Bool {
        for table in ["remote_asset_index_link", "remote_asset_index", "remote_asset_index_checkpoint"] {
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    "DELETE FROM \(table) WHERE key_epoch=?;",
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return false }
            bindText(stmt, 1, hashKeyEpoch)
            let succeeded = sqlite3_step(stmt) == SQLITE_DONE
            sqlite3_finalize(stmt)
            guard succeeded else { return false }
        }
        return true
    }

    private func writeRemoteAssetRecordsLocked(_ records: [UploadRemoteAssetIndexRecord]) -> Bool {
        guard !records.isEmpty else { return true }
        var recordStmt: OpaquePointer?
        var deleteLinksStmt: OpaquePointer?
        var linkStmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                """
                INSERT OR REPLACE INTO remote_asset_index(
                  key_epoch, external_id, revision_us, resource_count, primary_link
                ) VALUES(?,?,?,?,?);
                """,
                -1, &recordStmt, nil
            ) == SQLITE_OK,
            sqlite3_prepare_v2(
                db,
                "DELETE FROM remote_asset_index_link WHERE key_epoch=? AND external_id=? AND revision_us=?;",
                -1, &deleteLinksStmt, nil
            ) == SQLITE_OK,
            sqlite3_prepare_v2(
                db,
                """
                INSERT OR REPLACE INTO remote_asset_index_link(
                  key_epoch, external_id, revision_us, remote_link
                ) VALUES(?,?,?,?);
                """,
                -1, &linkStmt, nil
            ) == SQLITE_OK
        else {
            sqlite3_finalize(recordStmt)
            sqlite3_finalize(deleteLinksStmt)
            sqlite3_finalize(linkStmt)
            return false
        }
        defer {
            sqlite3_finalize(recordStmt)
            sqlite3_finalize(deleteLinksStmt)
            sqlite3_finalize(linkStmt)
        }

        for record in records {
            let links = Array(Set(record.remoteLinkIDs.filter { !$0.isEmpty })).sorted()
            guard !record.hashKeyEpoch.isEmpty,
                !record.externalIdentity.identifier.isEmpty,
                links.count == record.resourceCount,
                let primaryLink = record.remoteLinkIDs.first,
                links.contains(primaryLink)
            else { return false }

            sqlite3_reset(deleteLinksStmt)
            sqlite3_clear_bindings(deleteLinksStmt)
            bindText(deleteLinksStmt, 1, record.hashKeyEpoch)
            bindText(deleteLinksStmt, 2, record.externalIdentity.identifier)
            sqlite3_bind_int64(deleteLinksStmt, 3, record.externalIdentity.revision.rawValue)
            guard sqlite3_step(deleteLinksStmt) == SQLITE_DONE else { return false }

            sqlite3_reset(recordStmt)
            sqlite3_clear_bindings(recordStmt)
            bindText(recordStmt, 1, record.hashKeyEpoch)
            bindText(recordStmt, 2, record.externalIdentity.identifier)
            sqlite3_bind_int64(recordStmt, 3, record.externalIdentity.revision.rawValue)
            sqlite3_bind_int(recordStmt, 4, Int32(record.resourceCount))
            bindText(recordStmt, 5, primaryLink)
            guard sqlite3_step(recordStmt) == SQLITE_DONE else { return false }

            for link in links {
                sqlite3_reset(linkStmt)
                sqlite3_clear_bindings(linkStmt)
                bindText(linkStmt, 1, record.hashKeyEpoch)
                bindText(linkStmt, 2, record.externalIdentity.identifier)
                sqlite3_bind_int64(linkStmt, 3, record.externalIdentity.revision.rawValue)
                bindText(linkStmt, 4, link)
                guard sqlite3_step(linkStmt) == SQLITE_DONE else { return false }
            }
        }
        return true
    }

    private func invalidateRemoteAssetRecordsLocked(
        touching linkIDs: [String],
        hashKeyEpoch: String
    ) -> Bool {
        let unique = Set(linkIDs.filter { !$0.isEmpty })
        guard !unique.isEmpty else { return true }
        var deleteProofStmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                """
                DELETE FROM remote_asset_index
                WHERE key_epoch=? AND EXISTS(
                  SELECT 1 FROM remote_asset_index_link AS links
                  WHERE links.key_epoch=remote_asset_index.key_epoch
                    AND links.external_id=remote_asset_index.external_id
                    AND links.revision_us=remote_asset_index.revision_us
                    AND links.remote_link=?
                );
                """,
                -1, &deleteProofStmt, nil
            ) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(deleteProofStmt) }
        for linkID in unique {
            sqlite3_reset(deleteProofStmt)
            sqlite3_clear_bindings(deleteProofStmt)
            bindText(deleteProofStmt, 1, hashKeyEpoch)
            bindText(deleteProofStmt, 2, linkID)
            guard sqlite3_step(deleteProofStmt) == SQLITE_DONE else { return false }
        }

        var deleteOrphansStmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                """
                DELETE FROM remote_asset_index_link
                WHERE key_epoch=? AND NOT EXISTS(
                  SELECT 1 FROM remote_asset_index AS asset
                  WHERE asset.key_epoch=remote_asset_index_link.key_epoch
                    AND asset.external_id=remote_asset_index_link.external_id
                    AND asset.revision_us=remote_asset_index_link.revision_us
                );
                """,
                -1, &deleteOrphansStmt, nil
            ) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(deleteOrphansStmt) }
        bindText(deleteOrphansStmt, 1, hashKeyEpoch)
        return sqlite3_step(deleteOrphansStmt) == SQLITE_DONE
    }

    private func deleteRemoteContentLinksLocked(_ linkIDs: [String], hashKeyEpoch: String) -> Bool {
        let unique = Set(linkIDs.filter { !$0.isEmpty })
        guard !unique.isEmpty else { return true }
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                "DELETE FROM remote_content_index WHERE key_epoch=? AND remote_link=?;",
                -1, &stmt, nil
            ) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        for linkID in unique {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, hashKeyEpoch)
            bindText(stmt, 2, linkID)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return deleteUnresolvedRemoteLinksLocked(Array(unique), hashKeyEpoch: hashKeyEpoch)
    }

    private func writeUnresolvedRemoteIssuesLocked(
        _ issues: [UploadRemoteContentIndexIssue],
        hashKeyEpoch: String
    ) -> Bool {
        guard !issues.isEmpty else { return true }
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                """
                INSERT INTO remote_content_unresolved(
                  key_epoch,remote_link,reason,first_observed,last_observed,last_repair,generation
                ) VALUES(?,?,?,?,?,?,?)
                ON CONFLICT(key_epoch,remote_link) DO UPDATE SET
                  reason=excluded.reason,
                  first_observed=CASE
                    WHEN remote_content_unresolved.first_observed <= 0 THEN excluded.first_observed
                    ELSE MIN(remote_content_unresolved.first_observed,excluded.first_observed)
                  END,
                  last_observed=excluded.last_observed,
                  last_repair=excluded.last_repair,
                  generation=excluded.generation;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        for issue in issues {
            guard !issue.remoteLinkID.isEmpty, !issue.indexGeneration.isEmpty else { return false }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, hashKeyEpoch)
            bindText(stmt, 2, issue.remoteLinkID)
            bindText(stmt, 3, issue.reason.rawValue)
            sqlite3_bind_double(stmt, 4, issue.firstObservedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 5, issue.lastObservedAt.timeIntervalSince1970)
            if let attempted = issue.lastRepairAttemptAt {
                sqlite3_bind_double(stmt, 6, attempted.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            bindText(stmt, 7, issue.indexGeneration)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return true
    }

    private func deleteUnresolvedRemoteLinksLocked(
        _ linkIDs: [String],
        hashKeyEpoch: String
    ) -> Bool {
        let unique = Set(linkIDs.filter { !$0.isEmpty })
        guard !unique.isEmpty else { return true }
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                "DELETE FROM remote_content_unresolved WHERE key_epoch=? AND remote_link=?;",
                -1, &stmt, nil
            ) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        for linkID in unique {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, hashKeyEpoch)
            bindText(stmt, 2, linkID)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return true
    }

    private func readBuildCheckpointLocked(
        hashKeyEpoch: String
    ) -> UploadRemoteContentIndexBuildCheckpoint? {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                "SELECT build_id,event_id,source_fingerprint,cursor,total,updated_at FROM remote_content_build_checkpoint WHERE key_epoch=?;",
                -1, &stmt, nil
            ) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, hashKeyEpoch)
        guard sqlite3_step(stmt) == SQLITE_ROW,
            let buildID = columnText(stmt, 0),
            let eventID = columnText(stmt, 1),
            let sourceFingerprint = columnText(stmt, 2)
        else { return nil }
        return UploadRemoteContentIndexBuildCheckpoint(
            buildID: buildID,
            eventID: eventID,
            sourceFingerprint: sourceFingerprint,
            cursor: Int(sqlite3_column_int64(stmt, 3)),
            total: Int(sqlite3_column_int64(stmt, 4)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        )
    }

    private func readRemoteContentCheckpointLocked(
        hashKeyEpoch: String
    ) -> UploadRemoteContentIndexCheckpoint? {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                "SELECT event_id,refreshed_at FROM remote_content_index_checkpoint WHERE key_epoch=?;",
                -1, &stmt, nil
            ) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, hashKeyEpoch)
        guard sqlite3_step(stmt) == SQLITE_ROW, let eventID = columnText(stmt, 0) else { return nil }
        return UploadRemoteContentIndexCheckpoint(
            eventID: eventID,
            refreshedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        )
    }

    private func clearRemoteContentBuildLocked(hashKeyEpoch: String) -> Bool {
        for table in [
            "remote_content_build_record",
            "remote_content_build_unresolved",
            "remote_content_build_external",
            "remote_content_build_checkpoint",
        ] {
            guard executeBoundLocked("DELETE FROM \(table) WHERE key_epoch=?;", value: hashKeyEpoch) else {
                return false
            }
        }
        return true
    }

    private func executeBoundLocked(_ sql: String, value: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, value)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func writeBuildContentRecordsLocked(_ records: [UploadRemoteContentIndexRecord]) -> Bool {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                "INSERT OR REPLACE INTO remote_content_build_record(key_epoch,content_hash,remote_link) VALUES(?,?,?);",
                -1, &stmt, nil
            ) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        for record in records {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, record.hashKeyEpoch)
            bindText(stmt, 2, record.contentHash)
            bindText(stmt, 3, record.remoteLinkID)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return true
    }

    private func writeBuildUnresolvedLocked(
        _ issues: [UploadRemoteContentIndexIssue],
        hashKeyEpoch: String
    ) -> Bool {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                """
                INSERT INTO remote_content_build_unresolved(
                  key_epoch,remote_link,reason,first_observed,last_observed,last_repair,generation
                ) VALUES(?,?,?,?,?,?,?)
                ON CONFLICT(key_epoch,remote_link) DO UPDATE SET
                  reason=excluded.reason,
                  first_observed=CASE
                    WHEN remote_content_build_unresolved.first_observed <= 0 THEN excluded.first_observed
                    ELSE MIN(remote_content_build_unresolved.first_observed,excluded.first_observed)
                  END,
                  last_observed=excluded.last_observed,
                  last_repair=excluded.last_repair,
                  generation=excluded.generation;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        for issue in issues {
            guard !issue.remoteLinkID.isEmpty, !issue.indexGeneration.isEmpty else { return false }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, hashKeyEpoch)
            bindText(stmt, 2, issue.remoteLinkID)
            bindText(stmt, 3, issue.reason.rawValue)
            sqlite3_bind_double(stmt, 4, issue.firstObservedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 5, issue.lastObservedAt.timeIntervalSince1970)
            if let attempted = issue.lastRepairAttemptAt {
                sqlite3_bind_double(stmt, 6, attempted.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            bindText(stmt, 7, issue.indexGeneration)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return true
    }

    private func readBuildRemoteIssuesLocked(
        hashKeyEpoch: String
    ) -> [UploadRemoteContentIndexIssue]? {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                """
                SELECT remote_link,reason,first_observed,last_observed,last_repair,generation
                FROM remote_content_build_unresolved WHERE key_epoch=?;
                """,
                -1,
                &stmt,
                nil
            ) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, hashKeyEpoch)
        var issues: [UploadRemoteContentIndexIssue] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let linkID = columnText(stmt, 0),
                let rawReason = columnText(stmt, 1),
                let reason = UploadRemoteContentIndexIssue.Reason(rawValue: rawReason),
                let generation = columnText(stmt, 5)
            else { continue }
            issues.append(
                UploadRemoteContentIndexIssue(
                    remoteLinkID: linkID,
                    reason: reason,
                    firstObservedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    lastObservedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                    lastRepairAttemptAt: sqlite3_column_type(stmt, 4) == SQLITE_NULL
                        ? nil
                        : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                    indexGeneration: generation
                ))
        }
        return issues
    }

    private func deleteResolvedRemoteIssuesAfterBuildLocked(hashKeyEpoch: String) -> Bool {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                """
                DELETE FROM remote_content_unresolved
                WHERE key_epoch=?
                  AND NOT EXISTS (
                    SELECT 1 FROM remote_content_build_unresolved staged
                    WHERE staged.key_epoch=remote_content_unresolved.key_epoch
                      AND staged.remote_link=remote_content_unresolved.remote_link
                  );
                """,
                -1,
                &stmt,
                nil
            ) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, hashKeyEpoch)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func writeBuildExternalLocked(
        _ records: [UploadRemoteExternalIdentityRecord],
        hashKeyEpoch: String
    ) -> Bool {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                "INSERT OR REPLACE INTO remote_content_build_external(key_epoch,remote_link,external_id,revision_us) VALUES(?,?,?,?);",
                -1, &stmt, nil
            ) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        for record in records {
            guard !record.remoteLinkID.isEmpty, !record.externalIdentity.identifier.isEmpty else { return false }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, hashKeyEpoch)
            bindText(stmt, 2, record.remoteLinkID)
            bindText(stmt, 3, record.externalIdentity.identifier)
            sqlite3_bind_int64(stmt, 4, record.externalIdentity.revision.rawValue)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return true
    }

    private func updateBuildCursorLocked(
        hashKeyEpoch: String,
        buildID: String,
        nextCursor: Int,
        updatedAt: Date
    ) -> Bool {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                "UPDATE remote_content_build_checkpoint SET cursor=?,updated_at=? WHERE key_epoch=? AND build_id=?;",
                -1, &stmt, nil
            ) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(nextCursor))
        sqlite3_bind_double(stmt, 2, updatedAt.timeIntervalSince1970)
        bindText(stmt, 3, hashKeyEpoch)
        bindText(stmt, 4, buildID)
        return sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) == 1
    }

    private func writeRemoteContentCheckpointLocked(
        _ checkpoint: UploadRemoteContentIndexCheckpoint,
        hashKeyEpoch: String
    ) -> Bool {
        guard !hashKeyEpoch.isEmpty, !checkpoint.eventID.isEmpty else { return false }
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                """
                INSERT INTO remote_content_index_checkpoint(key_epoch, event_id, refreshed_at)
                VALUES(?,?,?) ON CONFLICT(key_epoch) DO UPDATE SET
                  event_id=excluded.event_id, refreshed_at=excluded.refreshed_at;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, hashKeyEpoch)
        bindText(stmt, 2, checkpoint.eventID)
        sqlite3_bind_double(stmt, 3, checkpoint.refreshedAt.timeIntervalSince1970)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func writeRemoteAssetCheckpointLocked(
        _ checkpoint: UploadRemoteContentIndexCheckpoint,
        hashKeyEpoch: String
    ) -> Bool {
        guard !hashKeyEpoch.isEmpty, !checkpoint.eventID.isEmpty else { return false }
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                """
                INSERT INTO remote_asset_index_checkpoint(key_epoch, event_id, refreshed_at)
                VALUES(?,?,?) ON CONFLICT(key_epoch) DO UPDATE SET
                  event_id=excluded.event_id, refreshed_at=excluded.refreshed_at;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, hashKeyEpoch)
        bindText(stmt, 2, checkpoint.eventID)
        sqlite3_bind_double(stmt, 3, checkpoint.refreshedAt.timeIntervalSince1970)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    // MARK: Column/bind helpers

    private let transient = SQLiteStoreSchemaGate.transientDestructor  // SQLITE_TRANSIENT

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: text)
    }
}
