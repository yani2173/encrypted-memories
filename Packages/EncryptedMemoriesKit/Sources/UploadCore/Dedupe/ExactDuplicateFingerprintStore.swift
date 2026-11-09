import Foundation
import PhotosCore
import SQLite3

/// Disposable photo details for the display filter. These values never authorize a merge or a backup.
public final class ExactDuplicateFingerprintStore: @unchecked Sendable {
    public static let databaseFileName = "duplicate-fingerprints-v1.sqlite"

    public struct Scope: Codable, Equatable, Sendable {
        public let accountID: String
        public let volumeID: String
        public let hashKeyEpoch: String

        public init(accountID: String, volumeID: String, hashKeyEpoch: String) {
            self.accountID = accountID
            self.volumeID = volumeID
            self.hashKeyEpoch = hashKeyEpoch
        }
    }

    /// A persisted context captured before the SDK read. Events revoke it before advancing the content index.
    public struct Snapshot: Codable, Equatable, Sendable {
        public let scope: Scope
        public let eventID: String
        let generation: String
    }

    private let connection: SQLiteStoreConnection

    /// The caller supplies its existing, canonical cache directory. Admission failures leave the cache unavailable.
    public init?(url: URL, cacheDirectory: URL, policy: LibraryDatabasePolicy = .conservative) {
        // Recovery may replace this cache, but must never open an authoritative store or follow a file symlink.
        guard url.isFileURL, url.lastPathComponent == Self.databaseFileName,
            Self.admitsPath(url, cacheDirectory: cacheDirectory)
        else { return nil }
        let schema = """
            CREATE TABLE fingerprint_context(id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL);
            CREATE TABLE fingerprint(link_id TEXT PRIMARY KEY, payload BLOB NOT NULL);
            """
        guard
            let db = SQLiteStoreSchemaGate.openRebuildableStore(
                at: url.standardized, schemaSQL: schema, policy: policy,
                verifyVersion: { db in
                    var statement: OpaquePointer?
                    guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK else {
                        return false
                    }
                    defer { sqlite3_finalize(statement) }
                    return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 1
                },
                stampVersion: { sqlite3_exec($0, "PRAGMA user_version=1;", nil, nil, nil) == SQLITE_OK }
            )
        else { return nil }
        connection = SQLiteStoreConnection(database: db, optimizesOnClose: false)
    }

    static func admitsPath(
        _ url: URL, cacheDirectory: URL,
        resourceValues: (URL, Set<URLResourceKey>) throws -> URLResourceValues = { try $0.resourceValues(forKeys: $1) }
    ) -> Bool {
        guard url.isFileURL, cacheDirectory.isFileURL else { return false }
        let file = URL(fileURLWithPath: url.standardized.path)
        let parent = file.deletingLastPathComponent()
        let expected = cacheDirectory.standardized
        let realParent = parent.resolvingSymlinksInPath()
        guard parent.path == realParent.path, realParent.path == expected.path else { return false }
        do {
            let values = try resourceValues(parent, [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink == false else { return false }
            // A directory listing proves a new leaf is absent; a failed resource read never proves absence.
            let children = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            // Treat case variants as occupied on every volume before checking the leaf.
            if children.contains(where: { $0.caseInsensitiveCompare(file.lastPathComponent) == .orderedSame }) {
                let leaf = try resourceValues(file, [.isSymbolicLinkKey])
                guard leaf.isSymbolicLink == false else { return false }
            }
            return true
        } catch {
            return false
        }
    }

    deinit { close() }

    public func close() { connection.close() }

    /// A discontinuity discards all saved details. An unchanged cursor preserves the persisted generation.
    /// Event IDs are opaque. The caller must order cursors before calling prepare or advance; this store cannot.
    public func prepare(scope: Scope, eventID: String) -> Snapshot? {
        guard !scope.accountID.isEmpty, !scope.volumeID.isEmpty, !scope.hashKeyEpoch.isEmpty, !eventID.isEmpty else {
            return nil
        }
        return transaction { db in
            if let current = self.current(db), current.scope == scope, current.eventID == eventID { return current }
            let next = Snapshot(scope: scope, eventID: eventID, generation: UUID().uuidString)
            guard self.execute(db, "DELETE FROM fingerprint;"), self.writeContext(next, db: db) else { return nil }
            return next
        }
    }

    /// Invalidate before the content index commits its new cursor. A failed advance cannot grant a new snapshot.
    public func advance(
        from snapshot: Snapshot, to eventID: String, invalidating linkIDs: Set<String>
    ) -> Snapshot? {
        guard !eventID.isEmpty else { return nil }
        return transaction { db in
            guard self.current(db) == snapshot else { return nil }
            for linkID in linkIDs {
                guard self.execute(db, "DELETE FROM fingerprint WHERE link_id=?;", text: linkID) else { return nil }
            }
            let next = Snapshot(scope: snapshot.scope, eventID: eventID, generation: UUID().uuidString)
            guard self.writeContext(next, db: db) else { return nil }
            return next
        }
    }

    @discardableResult
    public func store(_ fingerprints: [PhotoUID: ExactDuplicateFingerprint], for snapshot: Snapshot) -> Bool {
        var rows: [(String, Data)] = []
        for (uid, fingerprint) in fingerprints {
            guard uid.volumeID == snapshot.scope.volumeID,
                let saved = SavedFingerprint(fingerprint, uid: uid), let data = try? JSONEncoder().encode(saved)
            else { return false }
            rows.append((uid.nodeID, data))
        }
        return transaction { db -> Bool? in
            guard self.current(db) == snapshot else { return nil }
            for (linkID, data) in rows {
                guard self.execute(db, "INSERT OR REPLACE INTO fingerprint VALUES(?,?);", text: linkID, data: data)
                else {
                    return nil
                }
            }
            return true
        } ?? false
    }

    /// The details of every member of each group in `groups` whose members all have current details, in one read.
    /// A group with a missing, corrupt, foreign or stale member is left out whole, so it keeps the ranking path.
    public func fingerprints(
        ofGroups groups: [ExactDuplicateGroup], in snapshot: Snapshot
    ) -> [PhotoUID: ExactDuplicateFingerprint] {
        transaction(writing: false) { db in
            guard self.current(db) == snapshot else { return nil }
            var result: [PhotoUID: ExactDuplicateFingerprint] = [:]
            for group in groups
            where group.hashKeyEpoch == snapshot.scope.hashKeyEpoch
                && group.members.allSatisfy({ $0.volumeID == snapshot.scope.volumeID })
            {
                var saved: [PhotoUID: ExactDuplicateFingerprint] = [:]
                for uid in group.members {
                    let select = "SELECT payload FROM fingerprint WHERE link_id=?;"
                    guard let data = self.read(db, select, text: uid.nodeID),
                        let row = try? JSONDecoder().decode(SavedFingerprint.self, from: data)
                    else { break }
                    saved[uid] = row.fingerprint(for: uid)
                }
                if saved.count == group.members.count { result.merge(saved) { first, _ in first } }
            }
            return result
        } ?? [:]
    }

    private func transaction<Result>(writing: Bool = true, _ body: (OpaquePointer) -> Result?) -> Result? {
        connection.withLock {
            guard let db = connection.database, !connection.operationFailed,
                execute(db, writing ? "BEGIN IMMEDIATE;" : "BEGIN;")
            else { return nil }
            var committed = false
            defer { if !committed { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) } }
            guard let result = body(db), execute(db, "COMMIT;") else { return nil }
            committed = true
            return result
        }
    }

    private func current(_ db: OpaquePointer) -> Snapshot? {
        guard let data = read(db, "SELECT payload FROM fingerprint_context WHERE id=1;"),
            let current = try? JSONDecoder().decode(Snapshot.self, from: data),
            UUID(uuidString: current.generation) != nil
        else { return nil }
        return current
    }

    private func writeContext(_ snapshot: Snapshot, db: OpaquePointer) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        return execute(db, "INSERT OR REPLACE INTO fingerprint_context VALUES(1,?);", data: data)
    }

    private func execute(_ db: OpaquePointer, _ sql: String, text: String? = nil, data: Data? = nil) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            connection.markFailed()
            return false
        }
        defer { sqlite3_finalize(statement) }
        guard bind(statement, text: text, data: data), sqlite3_step(statement) == SQLITE_DONE else {
            connection.markFailed()
            return false
        }
        return true
    }

    private func read(_ db: OpaquePointer, _ sql: String, text: String? = nil) -> Data? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            connection.markFailed()
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard bind(statement, text: text) else {
            connection.markFailed()
            return nil
        }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            if step != SQLITE_DONE { connection.markFailed() }
            return nil
        }
        guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    private func bind(_ statement: OpaquePointer?, text: String? = nil, data: Data? = nil) -> Bool {
        let copy = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let text, sqlite3_bind_text(statement, 1, text, -1, copy) != SQLITE_OK { return false }
        if let data {
            return data.withUnsafeBytes {
                sqlite3_bind_blob64(statement, text == nil ? 1 : 2, $0.baseAddress, UInt64($0.count), copy) == SQLITE_OK
            }
        }
        return true
    }
}

/// Preserve the SDK's existing fingerprint values, including its node-only sentinel, without decoding attributes again.
private enum SavedFingerprint: Codable {
    case photo(Details)
    case nodeOnly

    init?(_ fingerprint: ExactDuplicateFingerprint, uid: PhotoUID) {
        if fingerprint == .matchingOnly(uid) {
            self = .nodeOnly
        } else {
            let details = Details(fingerprint)
            guard details.fingerprint == fingerprint else { return nil }
            self = .photo(details)
        }
    }

    func fingerprint(for uid: PhotoUID) -> ExactDuplicateFingerprint {
        switch self {
        case .nodeOnly: return .matchingOnly(uid)
        case .photo(let details): return details.fingerprint
        }
    }

    struct Details: Codable {
        let captureTime: Date?
        let latitude: Double?
        let longitude: Double?
        let device: String?
        let pixelWidth: Int?
        let pixelHeight: Int?
        let durationSeconds: Double?
        let mimeType: String?

        init(_ value: ExactDuplicateFingerprint) {
            captureTime = value.captureTime
            latitude = value.latitude
            longitude = value.longitude
            device = value.device
            pixelWidth = value.pixelWidth
            pixelHeight = value.pixelHeight
            durationSeconds = value.durationSeconds
            mimeType = value.mimeType
        }

        var fingerprint: ExactDuplicateFingerprint {
            ExactDuplicateFingerprint(
                captureTime: captureTime, latitude: latitude, longitude: longitude, device: device,
                pixelWidth: pixelWidth, pixelHeight: pixelHeight, durationSeconds: durationSeconds, mimeType: mimeType)
        }
    }
}
