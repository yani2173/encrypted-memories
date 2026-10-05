import Foundation
import PhotosCore
import SQLite3

public struct UploadRemoteLinkIdentityRecord: Sendable, Equatable {
    public let hashKeyEpoch: String
    public let remoteLinkID: String
    public let externalIdentifier: String
    public let isMain: Bool

    public init(hashKeyEpoch: String, remoteLinkID: String, externalIdentifier: String, isMain: Bool) {
        self.hashKeyEpoch = hashKeyEpoch
        self.remoteLinkID = remoteLinkID
        self.externalIdentifier = externalIdentifier
        self.isMain = isMain
    }
}

public struct UploadRemoteLineageRecord: Sendable, Equatable {
    public let hashKeyEpoch: String
    public let replacedLinkID: String
    public let replacingLinkID: String

    public init(hashKeyEpoch: String, replacedLinkID: String, replacingLinkID: String) {
        self.hashKeyEpoch = hashKeyEpoch
        self.replacedLinkID = replacedLinkID
        self.replacingLinkID = replacingLinkID
    }
}

public enum UploadRemoteLineageIndexHealth: Sendable, Equatable {
    case complete
    case incomplete
}

/// Rebuildable account cache. The upload manifest's exact schema stays unchanged.
public final class UploadRemoteLineageIndexStore: @unchecked Sendable {
    public static let databaseFileName = "remote-lineage-index-v1.sqlite"
    private var db: OpaquePointer?
    private let lock = NSLock()
    private var lookupFailed = false
    private let storePath: String
    /// Repair sweeps of this process for each key epoch: the last link read and the earliest start of the next sweep.
    private var repairCursors: [String: String] = [:]
    private var nextRepairSweeps: [String: Date] = [:]
    /// For each key epoch, when a repair read first found a link missing from a successful response.
    private var omittedSince: [String: [String: Date]] = [:]
    private let clock: @Sendable () -> Date
    // A write failure stays disabled for this file until process exit.
    private static let writeFailures = ProcessWriteFailures()
    private var writesDisabled: Bool { Self.writeFailures.contains(storePath) }

    private final class ProcessWriteFailures: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []

        func contains(_ path: String) -> Bool {
            lock.withLock { paths.contains(path) }
        }

        func insert(_ path: String) {
            lock.withLock { _ = paths.insert(path) }
        }
    }

    public init?(
        url: URL, policy: LibraryDatabasePolicy = .conservative, clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        storePath = url.standardizedFileURL.path
        self.clock = clock
        let schema = """
            CREATE TABLE remote_link_identity(
              key_epoch TEXT NOT NULL, remote_link TEXT NOT NULL,
              external_id TEXT NOT NULL, is_main INTEGER NOT NULL,
              PRIMARY KEY(key_epoch, remote_link)
            );
            CREATE INDEX remote_link_identity_lookup ON remote_link_identity(key_epoch, external_id, is_main);
            CREATE TABLE remote_lineage(
              key_epoch TEXT NOT NULL, replaced_link TEXT NOT NULL, replacing_link TEXT NOT NULL,
              PRIMARY KEY(key_epoch, replaced_link, replacing_link)
            );
            CREATE INDEX remote_lineage_owner ON remote_lineage(key_epoch, replacing_link);
            CREATE TABLE lineage_checkpoint(
              key_epoch TEXT PRIMARY KEY, event_id TEXT NOT NULL
            );
            CREATE TABLE lineage_unresolved(
              key_epoch TEXT NOT NULL, remote_link TEXT NOT NULL,
              PRIMARY KEY(key_epoch, remote_link)
            );
            CREATE TABLE lineage_build_unresolved(
              key_epoch TEXT NOT NULL, remote_link TEXT NOT NULL,
              PRIMARY KEY(key_epoch, remote_link)
            );
            CREATE TABLE lineage_build_identity(
              key_epoch TEXT NOT NULL, remote_link TEXT NOT NULL,
              external_id TEXT NOT NULL, is_main INTEGER NOT NULL,
              PRIMARY KEY(key_epoch, remote_link)
            );
            CREATE TABLE lineage_build_record(
              key_epoch TEXT NOT NULL, replaced_link TEXT NOT NULL, replacing_link TEXT NOT NULL,
              PRIMARY KEY(key_epoch, replaced_link, replacing_link)
            );
            CREATE TABLE lineage_build_checkpoint(
              key_epoch TEXT PRIMARY KEY, build_id TEXT NOT NULL, event_id TEXT NOT NULL,
              cursor INTEGER NOT NULL
            );
            """
        guard
            let handle = SQLiteStoreSchemaGate.openRebuildableStore(
                at: url, schemaSQL: schema, policy: policy,
                verifyVersion: { handle in
                    var statement: OpaquePointer?
                    guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK else {
                        return false
                    }
                    defer { sqlite3_finalize(statement) }
                    return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 2
                },
                stampVersion: { sqlite3_exec($0, "PRAGMA user_version=2;", nil, nil, nil) == SQLITE_OK }
            )
        else { return nil }
        db = handle
    }

    deinit { close() }

    public func close() {
        lock.withLock {
            guard let db else { return }
            sqlite3_close(db)
            self.db = nil
        }
    }

    /// False after a write failure or close; a rebuild then cannot fill the index.
    public var acceptsWrites: Bool {
        lock.withLock { db != nil && !writesDisabled }
    }

    public func hasCheckpoint(hashKeyEpoch: String, eventID: String) -> Bool {
        lock.withLock { !writesDisabled && checkpointLocked(hashKeyEpoch: hashKeyEpoch) == eventID }
    }

    public func health(
        hashKeyEpoch: String, contentCheckpoint: UploadRemoteContentIndexCheckpoint?
    ) -> UploadRemoteLineageIndexHealth {
        lock.withLock {
            guard !writesDisabled, !lookupFailed, let contentCheckpoint,
                checkpointLocked(hashKeyEpoch: hashKeyEpoch) == contentCheckpoint.eventID,
                hasNoUnresolvedLinksLocked(hashKeyEpoch: hashKeyEpoch)
            else { return .incomplete }
            return .complete
        }
    }

    public func activeMainLinkIDs(forExternalIdentifier identifier: String, hashKeyEpoch: String) -> Set<String> {
        lock.withLock {
            linksLocked(
                "SELECT remote_link FROM remote_link_identity WHERE key_epoch=? AND external_id=? AND is_main=1;",
                values: [hashKeyEpoch, identifier])
        }
    }

    public func replacingMainLinkIDs(ofReplacedLink linkID: String, hashKeyEpoch: String) -> Set<String> {
        lock.withLock {
            linksLocked(
                "SELECT replacing_link FROM remote_lineage WHERE key_epoch=? AND replaced_link=?;",
                values: [hashKeyEpoch, linkID])
        }
    }

    public func externalIdentifier(ofMainLink linkID: String, hashKeyEpoch: String) -> String? {
        lock.withLock {
            linksLocked(
                "SELECT external_id FROM remote_link_identity WHERE key_epoch=? AND remote_link=? AND is_main=1;",
                values: [hashKeyEpoch, linkID]
            ).first
        }
    }

    public func replacedLinkIDs(ofReplacingMain linkID: String, hashKeyEpoch: String) -> Set<String> {
        lock.withLock {
            linksLocked(
                "SELECT replaced_link FROM remote_lineage WHERE key_epoch=? AND replacing_link=?;",
                values: [hashKeyEpoch, linkID])
        }
    }

    /// The next unresolved links to read again, at most `limit`. A sweep walks the links in order; after its end the
    /// next sweep waits `sweepInterval`, so a link that keeps failing costs one read for each interval.
    public func unresolvedLinkIDsForRepair(hashKeyEpoch: String, limit: Int, sweepInterval: TimeInterval) -> [String] {
        lock.withLock {
            guard limit > 0, !writesDisabled else { return [] }
            let now = clock()
            let cursor = repairCursors[hashKeyEpoch]
            if cursor == nil, let next = nextRepairSweeps[hashKeyEpoch], now < next { return [] }
            guard
                let links = columnLocked(
                    "SELECT remote_link FROM lineage_unresolved WHERE key_epoch=? AND remote_link>? "
                        + "ORDER BY remote_link LIMIT \(limit);",
                    values: [hashKeyEpoch, cursor ?? ""])
            else { return [] }
            if links.count < limit {
                repairCursors[hashKeyEpoch] = nil
                nextRepairSweeps[hashKeyEpoch] = now.addingTimeInterval(sweepInterval)
            } else {
                repairCursors[hashKeyEpoch] = links.last
            }
            return links
        }
    }

    /// The links that leave the index as gone: two repair reads at least `interval` apart found each of them missing
    /// from a successful response. Proton leaves out a link that is deleted for good, but one omission can also be a
    /// partial response. A link that a read returns starts over.
    public func linksOmittedTwice(
        omitted: Set<String>, returned: Set<String>, hashKeyEpoch: String, interval: TimeInterval
    ) -> Set<String> {
        lock.withLock {
            let now = clock()
            var since = omittedSince[hashKeyEpoch, default: [:]]
            for linkID in returned { since[linkID] = nil }
            var settled: Set<String> = []
            for linkID in omitted {
                if let first = since[linkID] {
                    guard now.timeIntervalSince(first) >= interval else { continue }
                    settled.insert(linkID)
                    since[linkID] = nil
                } else {
                    since[linkID] = now
                }
            }
            omittedSince[hashKeyEpoch] = since.isEmpty ? nil : since
            return settled
        }
    }

    @discardableResult
    public func replaceRows(
        identities: [UploadRemoteLinkIdentityRecord], lineage: [UploadRemoteLineageRecord],
        hashKeyEpoch: String, eventID: String, unresolvedRemoteLinkIDs: Set<String>
    ) -> Bool {
        lock.withLock {
            let replaced = transactionLocked {
                clearPublishedLocked()
                    && clearOtherBuildEpochsLocked(hashKeyEpoch)
                    && writeRowsLocked(identities, lineage, hashKeyEpoch: hashKeyEpoch)
                    && writeUnresolvedLocked(unresolvedRemoteLinkIDs, hashKeyEpoch: hashKeyEpoch)
                    && writeCheckpointLocked(hashKeyEpoch, eventID: eventID)
            }
            if replaced { restartRepairSweepLocked(hashKeyEpoch) }
            return replaced
        }
    }

    @discardableResult
    public func applyChanges(
        identities: [UploadRemoteLinkIdentityRecord], lineage: [UploadRemoteLineageRecord],
        removingRemoteLinkIDs: [String], hashKeyEpoch: String, expectedEventID: String,
        eventID: String, unresolvedRemoteLinkIDs: Set<String>
    ) -> Bool {
        lock.withLock {
            guard !writesDisabled, checkpointLocked(hashKeyEpoch: hashKeyEpoch) == expectedEventID else { return false }
            return transactionLocked(expectedCheckpoint: (hashKeyEpoch, expectedEventID)) {
                for linkID in removingRemoteLinkIDs {
                    guard
                        executeLocked(
                            "DELETE FROM remote_link_identity WHERE key_epoch=? AND remote_link=?;",
                            values: [hashKeyEpoch, linkID]),
                        executeLocked(
                            "DELETE FROM remote_lineage WHERE key_epoch=? AND replacing_link=?;",
                            values: [hashKeyEpoch, linkID]),
                        executeLocked(
                            "DELETE FROM lineage_unresolved WHERE key_epoch=? AND remote_link=?;",
                            values: [hashKeyEpoch, linkID])
                    else { return false }
                }
                return writeRowsLocked(identities, lineage, hashKeyEpoch: hashKeyEpoch)
                    && writeUnresolvedLocked(unresolvedRemoteLinkIDs, hashKeyEpoch: hashKeyEpoch)
                    && writeCheckpointLocked(hashKeyEpoch, eventID: eventID)
            }
        }
    }

    /// Staging follows the content build cursor. Published rows stay unchanged until finish.
    public func prepareBuild(_ build: UploadRemoteContentIndexBuildCheckpoint, hashKeyEpoch: String) -> Bool {
        lock.withLock {
            guard !writesDisabled else { return false }
            if let cursor = buildCursorLocked(
                hashKeyEpoch: hashKeyEpoch, buildID: build.buildID, eventID: build.eventID)
            {
                return cursor >= build.cursor
            }
            // Missing staging cannot restart a content build.
            guard build.cursor == 0 else { return false }
            return transactionLocked {
                clearBuildLocked(hashKeyEpoch)
                    && executeLocked(
                        "INSERT INTO lineage_build_checkpoint VALUES(?,?,?,0);",
                        values: [hashKeyEpoch, build.buildID, build.eventID])
            }
        }
    }

    @discardableResult
    public func appendBuild(
        identities: [UploadRemoteLinkIdentityRecord], lineage: [UploadRemoteLineageRecord],
        hashKeyEpoch: String, buildID: String, nextCursor: Int, unresolvedRemoteLinkIDs: Set<String>
    ) -> Bool {
        guard nextCursor >= 0 else { return false }
        return lock.withLock {
            guard !writesDisabled, let cursor = buildCursorLocked(hashKeyEpoch: hashKeyEpoch, buildID: buildID) else {
                return false
            }
            guard cursor < nextCursor else { return true }
            return transactionLocked {
                writeRowsLocked(identities, lineage, hashKeyEpoch: hashKeyEpoch, staging: true)
                    && writeUnresolvedLocked(unresolvedRemoteLinkIDs, hashKeyEpoch: hashKeyEpoch, staging: true)
                    && executeLocked(
                        "UPDATE lineage_build_checkpoint SET cursor=? WHERE key_epoch=? AND build_id=?;",
                        values: [String(nextCursor), hashKeyEpoch, buildID])
                    && sqlite3_changes(db) == 1
            }
        }
    }

    @discardableResult
    public func finishBuild(_ build: UploadRemoteContentIndexBuildCheckpoint, hashKeyEpoch: String) -> Bool {
        lock.withLock {
            guard !writesDisabled else { return false }
            // Checked inside the transaction: another connection may prepare a new build between check and write.
            let finished = transactionLocked(
                precondition: {
                    buildCursorLocked(hashKeyEpoch: hashKeyEpoch, buildID: build.buildID, eventID: build.eventID)
                        == build.total
                }
            ) {
                clearPublishedLocked()
                    && executeLocked(
                        "INSERT INTO remote_link_identity SELECT * FROM lineage_build_identity WHERE key_epoch=?;",
                        values: [hashKeyEpoch])
                    && executeLocked(
                        "INSERT INTO remote_lineage SELECT * FROM lineage_build_record WHERE key_epoch=?;",
                        values: [hashKeyEpoch])
                    && executeLocked(
                        "INSERT INTO lineage_unresolved SELECT * FROM lineage_build_unresolved WHERE key_epoch=?;",
                        values: [hashKeyEpoch])
                    && writeCheckpointLocked(hashKeyEpoch, eventID: build.eventID)
                    && clearBuildLocked(hashKeyEpoch)
                    && clearOtherBuildEpochsLocked(hashKeyEpoch)
            }
            if finished { restartRepairSweepLocked(hashKeyEpoch) }
            return finished
        }
    }

    /// A new unresolved set is read at once, not after the interval of the previous sweep.
    private func restartRepairSweepLocked(_ epoch: String) {
        repairCursors[epoch] = nil
        nextRepairSweeps[epoch] = nil
    }

    private func checkpointLocked(hashKeyEpoch: String) -> String? {
        var statement: OpaquePointer?
        guard
            prepareLocked(
                "SELECT event_id FROM lineage_checkpoint WHERE key_epoch=?;",
                values: [hashKeyEpoch], statement: &statement)
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private func hasNoUnresolvedLinksLocked(hashKeyEpoch: String) -> Bool {
        var statement: OpaquePointer?
        guard
            prepareLocked(
                "SELECT 1 FROM lineage_unresolved WHERE key_epoch=? LIMIT 1;",
                values: [hashKeyEpoch], statement: &statement)
        else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func buildCursorLocked(hashKeyEpoch: String, buildID: String, eventID: String? = nil) -> Int? {
        var statement: OpaquePointer?
        var sql = "SELECT cursor FROM lineage_build_checkpoint WHERE key_epoch=? AND build_id=?"
        var values = [hashKeyEpoch, buildID]
        if let eventID {
            sql += " AND event_id=?"
            values.append(eventID)
        }
        guard prepareLocked(sql + ";", values: values, statement: &statement) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func writeRowsLocked(
        _ identities: [UploadRemoteLinkIdentityRecord], _ lineage: [UploadRemoteLineageRecord],
        hashKeyEpoch: String, staging: Bool = false
    ) -> Bool {
        guard !hashKeyEpoch.isEmpty else { return false }
        let identityTable = staging ? "lineage_build_identity" : "remote_link_identity"
        let lineageTable = staging ? "lineage_build_record" : "remote_lineage"
        for row in identities {
            guard row.hashKeyEpoch == hashKeyEpoch, !row.remoteLinkID.isEmpty, !row.externalIdentifier.isEmpty,
                executeLocked(
                    "INSERT OR REPLACE INTO \(identityTable) VALUES(?,?,?,?);",
                    values: [hashKeyEpoch, row.remoteLinkID, row.externalIdentifier, row.isMain ? "1" : "0"])
            else { return false }
        }
        for row in lineage {
            guard row.hashKeyEpoch == hashKeyEpoch, !row.replacedLinkID.isEmpty, !row.replacingLinkID.isEmpty,
                executeLocked(
                    "INSERT OR IGNORE INTO \(lineageTable) VALUES(?,?,?);",
                    values: [hashKeyEpoch, row.replacedLinkID, row.replacingLinkID])
            else { return false }
        }
        return true
    }

    private func writeUnresolvedLocked(
        _ linkIDs: Set<String>, hashKeyEpoch: String, staging: Bool = false
    ) -> Bool {
        let table = staging ? "lineage_build_unresolved" : "lineage_unresolved"
        return linkIDs.allSatisfy { linkID in
            !linkID.isEmpty
                && executeLocked(
                    "INSERT OR IGNORE INTO \(table) VALUES(?,?);", values: [hashKeyEpoch, linkID])
        }
    }

    private func writeCheckpointLocked(_ epoch: String, eventID: String) -> Bool {
        guard !epoch.isEmpty, !eventID.isEmpty else { return false }
        return executeLocked("INSERT OR REPLACE INTO lineage_checkpoint VALUES(?,?);", values: [epoch, eventID])
    }

    private func clearPublishedLocked() -> Bool {
        ["remote_link_identity", "remote_lineage", "lineage_checkpoint", "lineage_unresolved"].allSatisfy {
            executeLocked("DELETE FROM \($0);", values: [])
        }
    }

    private func clearBuildLocked(_ epoch: String) -> Bool {
        ["lineage_build_identity", "lineage_build_record", "lineage_build_checkpoint", "lineage_build_unresolved"]
            .allSatisfy {
                executeLocked("DELETE FROM \($0) WHERE key_epoch=?;", values: [epoch])
            }
    }

    private func clearOtherBuildEpochsLocked(_ epoch: String) -> Bool {
        ["lineage_build_identity", "lineage_build_record", "lineage_build_checkpoint", "lineage_build_unresolved"]
            .allSatisfy {
                executeLocked("DELETE FROM \($0) WHERE key_epoch<>?;", values: [epoch])
            }
    }

    private func transactionLocked(
        expectedCheckpoint: (epoch: String, eventID: String)? = nil, precondition: () -> Bool = { true },
        _ operation: () -> Bool
    ) -> Bool {
        guard !writesDisabled else { return false }
        // A store closed at sign-out writes nothing; that is no failure of the file.
        guard db != nil else { return false }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            Self.writeFailures.insert(storePath)
            return false
        }
        if let expectedCheckpoint,
            checkpointLocked(hashKeyEpoch: expectedCheckpoint.epoch) != expectedCheckpoint.eventID
        {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return false
        }
        // A state that another connection changed is no write failure; the store stays usable.
        guard precondition() else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return false
        }
        guard operation(), sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            Self.writeFailures.insert(storePath)
            return false
        }
        return true
    }

    private func linksLocked(_ sql: String, values: [String]) -> Set<String> {
        lookupFailed = true
        guard let rows = columnLocked(sql, values: values) else { return [] }
        lookupFailed = false
        return Set(rows)
    }

    /// The first column of every row in order, or nil when the read fails.
    private func columnLocked(_ sql: String, values: [String]) -> [String]? {
        var statement: OpaquePointer?
        guard prepareLocked(sql, values: values, statement: &statement) else { return nil }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let text = sqlite3_column_text(statement, 0) else { return nil }
                result.append(String(cString: text))
            case SQLITE_DONE: return result
            default: return nil
            }
        }
    }

    private func executeLocked(_ sql: String, values: [String]) -> Bool {
        var statement: OpaquePointer?
        guard prepareLocked(sql, values: values, statement: &statement) else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func prepareLocked(_ sql: String, values: [String], statement: inout OpaquePointer?) -> Bool {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            statement = nil
            return false
        }
        for (offset, value) in values.enumerated() {
            guard
                sqlite3_bind_text(
                    statement, Int32(offset + 1), value, -1, SQLiteStoreSchemaGate.transientDestructor) == SQLITE_OK
            else {
                sqlite3_finalize(statement)
                statement = nil
                return false
            }
        }
        return true
    }
}
