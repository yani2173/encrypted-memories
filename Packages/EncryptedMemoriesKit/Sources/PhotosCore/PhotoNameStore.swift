import CryptoKit
import Foundation
import SQLite3

/// The decrypted file names of one account, sealed on disk and read for search.
///
/// Each row holds one photo: its volume and node identifiers and its name, AES-GCM sealed with a key derived from
/// the session key password and the account UID. The additional data binds every sealed name to its volume and node,
/// so a row copied onto another photo does not open. An empty name records a photo whose name could not be read; it
/// stops repeated requests and never matches a query. A photo without a row still needs its name.
///
/// The file lives in the account library directory, so the sign-out purge removes it with `library-v1.sqlite`.
/// A search builds the decrypted index on its first query and keeps it until the search ends (`endSearch()`), a write
/// changes the file, or the memory budget falls below normal; while the budget stays below normal no index is kept.
/// Names never reach logs or diagnostics, only counts do.
public final class PhotoNameStore: MemoryPressureResponder, @unchecked Sendable {
    public static let databaseFileName = "photo-names-v1.sqlite"

    public enum WriteResult: Equatable, Sendable {
        case written
        /// A name was forgotten after the caller took its token; nothing was written, so a later read fetches it again.
        case superseded
        case failed
    }

    private let lock = NSLock()
    private var db: OpaquePointer?
    private let key: SymmetricKey
    private let transient = SQLiteStoreSchemaGate.transientDestructor
    private var cachedIndex: PhotoNameIndex?
    private var cachesIndex = true
    private var revision: UInt64 = 0
    private var forgetCount: UInt64 = 0
    private var memoryRegistration: MemoryPressureRegistration?

    public init?(
        directory: URL, accountUID: String, keyPassword: String, policy: LibraryDatabasePolicy = .conservative
    ) {
        let input = SymmetricKey(data: Data(keyPassword.utf8))
        let salt = Data("EncryptedMemories.photo-names.v1.\(accountUID)".utf8)
        key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: input, salt: salt, info: Data("photo-names".utf8), outputByteCount: 32)
        let url = directory.appendingPathComponent(Self.databaseFileName)
        db = SQLiteStoreSchemaGate.openRebuildableStore(
            at: url, schemaSQL: Self.schema, policy: policy,
            verifyVersion: { handle in
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
                    return false
                }
                defer { sqlite3_finalize(stmt) }
                return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) == 1
            },
            stampVersion: { sqlite3_exec($0, "PRAGMA user_version=1;", nil, nil, nil) == SQLITE_OK })
        guard db != nil else { return nil }
    }

    deinit { close() }

    public func close() {
        let registration = lock.withLock {
            sqlite3_close(db)
            db = nil
            cachedIndex = nil
            defer { memoryRegistration = nil }
            return memoryRegistration
        }
        if let registration { Task { @MainActor in registration.end() } }
    }

    /// Registers with `governor` until `close()`. A store closed before this runs stays unregistered.
    @MainActor public func registerForMemoryPressure(_ governor: MemoryPressureGovernor) {
        guard lock.withLock({ db != nil && memoryRegistration == nil }) else { return }
        let registration = governor.register(self)
        let kept = lock.withLock {
            guard db != nil else { return false }
            memoryRegistration = registration
            return true
        }
        if !kept { registration.end() }
    }

    private static let schema = """
        CREATE TABLE photo_name(
          vol TEXT NOT NULL, node TEXT NOT NULL, sealed BLOB NOT NULL,
          PRIMARY KEY(vol, node)
        ) WITHOUT ROWID;
        """

    /// The node IDs of `volumeID` that have a row, read without opening a name. Nil when the file cannot be read.
    public func recordedNodeIDs(volumeID: String) -> Set<String>? {
        lock.withLock {
            guard let db else { return nil }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT node FROM photo_name WHERE vol=?1;", -1, &stmt, nil) == SQLITE_OK
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, volumeID, -1, transient)
            var nodes = Set<String>()
            while true {
                switch sqlite3_step(stmt) {
                case SQLITE_ROW:
                    if let text = sqlite3_column_text(stmt, 0) { nodes.insert(String(cString: text)) }
                case SQLITE_DONE:
                    return nodes
                default:
                    return nil
                }
            }
        }
    }

    /// Taken before a name read; `record(_:unlessForgottenSince:)` rejects the read when a name was forgotten
    /// meanwhile.
    public var forgetToken: UInt64 {
        lock.withLock { forgetCount }
    }

    /// Stores names in one transaction; an empty name records an unreadable one. With a token, nothing is written when
    /// a name was forgotten since the token, because the read may predate a rename. Only `.written` changes the file.
    @discardableResult
    public func record(_ names: [PhotoUID: String], unlessForgottenSince token: UInt64? = nil) -> WriteResult {
        guard !names.isEmpty else { return .written }
        return lock.withLock {
            guard let db else { return .failed }
            if let token, token != forgetCount { return .superseded }
            var sealed: [(PhotoUID, Data)] = []
            sealed.reserveCapacity(names.count)
            for (uid, name) in names {
                guard let box = try? AES.GCM.seal(Data(name.utf8), using: key, authenticating: Self.binding(uid)),
                    let combined = box.combined
                else { return .failed }
                sealed.append((uid, combined))
            }
            let written = transaction(db) {
                var stmt: OpaquePointer?
                guard
                    sqlite3_prepare_v2(
                        db, "INSERT OR REPLACE INTO photo_name(vol,node,sealed) VALUES(?1,?2,?3);", -1, &stmt, nil)
                        == SQLITE_OK
                else { return false }
                defer { sqlite3_finalize(stmt) }
                for (uid, blob) in sealed {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, uid.volumeID, -1, transient)
                    sqlite3_bind_text(stmt, 2, uid.nodeID, -1, transient)
                    let bound = blob.withUnsafeBytes {
                        sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32($0.count), transient)
                    }
                    guard bound == SQLITE_OK, sqlite3_step(stmt) == SQLITE_DONE else { return false }
                }
                return true
            }
            guard written else { return .failed }
            revision &+= 1
            cachedIndex = nil
            return .written
        }
    }

    /// Removes the names of `uids`, so the next metadata pass reads them again.
    @discardableResult
    public func forget(_ uids: Set<PhotoUID>) -> Bool {
        guard !uids.isEmpty else { return true }
        return lock.withLock {
            guard let db else { return false }
            let removed = transaction(db) { deleteRows(db, uids) }
            guard removed else { return false }
            revision &+= 1
            forgetCount &+= 1
            cachedIndex = nil
            return true
        }
    }

    /// The decrypted index for an open search, read from the file when no index is kept. A row that does not open
    /// (another key, damage) is removed, so the next metadata pass reads that name again.
    public func index() -> PhotoNameIndex {
        lock.withLock {
            if let cachedIndex { return cachedIndex }
            guard let db else { return .empty }
            // Built with the index keys directly, so loading holds no second copy of the long identifiers.
            var names: [Int: String] = [:]
            var unreadable = Set<PhotoUID>()
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT vol,node,sealed FROM photo_name;", -1, &stmt, nil) == SQLITE_OK
            else { return .empty }
            var complete = false
            while true {
                let step = sqlite3_step(stmt)
                if step == SQLITE_DONE { complete = true }
                guard step == SQLITE_ROW,
                    let vol = sqlite3_column_text(stmt, 0), let node = sqlite3_column_text(stmt, 1)
                else { break }
                let uid = PhotoUID(volumeID: String(cString: vol), nodeID: String(cString: node))
                let count = Int(sqlite3_column_bytes(stmt, 2))
                let blob = sqlite3_column_blob(stmt, 2).map { Data(bytes: $0, count: count) } ?? Data()
                if let box = try? AES.GCM.SealedBox(combined: blob),
                    let plain = try? AES.GCM.open(box, using: key, authenticating: Self.binding(uid)),
                    let name = String(data: plain, encoding: .utf8)
                {
                    if !name.isEmpty { names[PhotoNameIndex.key(uid)] = SearchTextNormalization.normalize(name) }
                } else {
                    unreadable.insert(uid)
                }
            }
            sqlite3_finalize(stmt)
            if !unreadable.isEmpty, transaction(db, { deleteRows(db, unreadable) }) {
                PhotoDiagnostics.shared.increment("photoNames.unreadableRowRemoved", by: unreadable.count)
            }
            let index = PhotoNameIndex(normalizedNames: names, revision: revision)
            // A partial read is served once but not kept, so the next query reads the file again.
            if complete, cachesIndex { cachedIndex = index }
            return index
        }
    }

    /// The search ended: the store keeps no decrypted names. The sealed file stays.
    public func endSearch() {
        lock.withLock { cachedIndex = nil }
    }

    /// Any tier below normal (memory pressure, heat, or the app in the background) drops the decrypted names and keeps
    /// none until the budget is normal again.
    @MainActor public func respondToMemoryBudget(_ tier: MemoryBudgetTier) {
        lock.withLock {
            cachesIndex = tier == .normal
            if !cachesIndex { cachedIndex = nil }
        }
    }

    private static func binding(_ uid: PhotoUID) -> Data {
        Data("\(uid.volumeID)\u{0}\(uid.nodeID)".utf8)
    }

    private func deleteRows(_ db: OpaquePointer, _ uids: Set<PhotoUID>) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM photo_name WHERE vol=?1 AND node=?2;", -1, &stmt, nil) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        for uid in uids {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, uid.volumeID, -1, transient)
            sqlite3_bind_text(stmt, 2, uid.nodeID, -1, transient)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return true
    }

    private func transaction(_ db: OpaquePointer, _ body: () -> Bool) -> Bool {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
        guard body(), sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return false
        }
        return true
    }
}
