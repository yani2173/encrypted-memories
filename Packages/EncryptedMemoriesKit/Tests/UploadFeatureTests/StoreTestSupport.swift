import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

/// The SQLite connection of a store, read through reflection, so a fixture can act on the store's own connection.
/// Pass the store itself: an implicitly unwrapped property passed as `Any` reflects as an Optional and has no
/// `connection` child.
func storeConnection(_ store: Any) throws -> SQLiteStoreConnection {
    try XCTUnwrap(
        Mirror(reflecting: store).children.first(where: { $0.label == "connection" })?.value as? SQLiteStoreConnection)
}

/// Pending-grid effects that succeed without doing anything.
struct InertPendingEffects: PendingBackupEffects {
    func removeFromBackup(kind: UploadSourceIdentity.Kind, identifiers: [String]) async -> Bool { true }
    func returnToBackup(_ keys: [PendingSourceKey]) async -> Set<PendingSourceKey> { Set(keys) }
    func photosVolumeID() async -> String? { "volume" }
    func trashRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func restoreRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult { .done }
    func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult { .done }
    func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult { .done }
}

/// Fails every statement whose expanded SQL matches, until `stop()` or until it failed `failures` statements. Other
/// statements and probes run normally. With `fails: false` it only counts the matching statement runs.
final class SQLiteStatementFaults {
    private let connection: SQLiteStoreConnection
    private let matches: (String) -> Bool
    private let fails: Bool
    private let failures: Int
    private var statement: UnsafeMutableRawPointer?
    private var fired = 0
    private var matched = 0
    private var stopped = false

    init(in store: Any, fails: Bool = true, failures: Int = .max, matches: @escaping (String) -> Bool) throws {
        connection = try storeConnection(store)
        self.matches = matches
        self.fails = fails
        self.failures = failures
        connection.withLock {
            sqlite3_trace_v2(
                connection.database, UInt32(SQLITE_TRACE_STMT),
                { _, context, statement, _ in
                    guard let context, let statement else { return 0 }
                    let faults = Unmanaged<SQLiteStatementFaults>.fromOpaque(context).takeUnretainedValue()
                    faults.statement = nil
                    guard let expanded = sqlite3_expanded_sql(OpaquePointer(statement)) else { return 0 }
                    defer { sqlite3_free(expanded) }
                    guard faults.matches(String(cString: expanded)) else { return 0 }
                    faults.matched += 1
                    if faults.fails, faults.fired < faults.failures { faults.statement = statement }
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
            sqlite3_progress_handler(
                connection.database, 1,
                { context in
                    guard let context else { return 0 }
                    let faults = Unmanaged<SQLiteStatementFaults>.fromOpaque(context).takeUnretainedValue()
                    guard faults.statement != nil else { return 0 }
                    faults.statement = nil
                    faults.fired += 1
                    return 1
                }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    var firedCount: Int { connection.withLock { fired } }
    var matchedCount: Int { connection.withLock { matched } }

    func stop() {
        connection.withLock {
            guard !stopped, connection.database != nil else { return }
            stopped = true
            sqlite3_trace_v2(connection.database, 0, nil, nil)
            sqlite3_progress_handler(connection.database, 0, nil, nil)
        }
    }
}

/// Records one transient failure on the store's connection while the first statement whose SQL contains `matching`
/// runs, without failing that statement. The failure stands for another reader of the same connection; the store's
/// health check forgets it at once, because the database answers.
final class SQLiteRecordedFailure {
    private let connection: SQLiteStoreConnection
    private let matching: String
    private var marked = false

    init(in store: Any, matching: String) throws {
        connection = try storeConnection(store)
        self.matching = matching
        connection.withLock {
            sqlite3_trace_v2(
                connection.database, UInt32(SQLITE_TRACE_STMT),
                { _, context, statement, _ in
                    guard let context, let statement else { return 0 }
                    let mark = Unmanaged<SQLiteRecordedFailure>.fromOpaque(context).takeUnretainedValue()
                    guard !mark.marked, let sql = sqlite3_sql(OpaquePointer(statement)),
                        String(cString: sql).contains(mark.matching)
                    else { return 0 }
                    // The trace runs while the store holds its connection lock, as `markFailed` requires.
                    mark.marked = true
                    mark.connection.markFailed(resultCode: SQLITE_INTERRUPT)
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    var recorded: Bool { connection.withLock { marked } }

    func stop() {
        connection.withLock {
            guard connection.database != nil else { return }
            sqlite3_trace_v2(connection.database, 0, nil, nil)
        }
    }
}

/// Stores `key` as an INTEGER in `local_id` of the catalog row `localIdentifier`, as only damage to the file can: SQL
/// converts a number to text for a TEXT column, and this SQLite refuses `writable_schema`. With the store closed, the
/// declared type in the file becomes BLOB, which has the same length, for one update, and then TEXT again.
func storeIntegerCatalogKey(_ key: Int, replacing localIdentifier: String, inClosedCatalogAt url: URL) throws {
    func withDatabase<Value>(_ body: (OpaquePointer) throws -> Value) throws -> Value {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let database = try XCTUnwrap(handle)
        defer { sqlite3_close(database) }
        return try body(database)
    }
    func run(_ sql: String) throws {
        try withDatabase { database in
            XCTAssertEqual(
                sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(database)))
        }
    }
    func text(_ sql: String) throws -> String? {
        try withDatabase { database in
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &stmt, nil), SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: value)
        }
    }
    func declare(_ from: String, as to: String) throws {
        try run("PRAGMA wal_checkpoint(TRUNCATE);")
        var image = try Data(contentsOf: url)
        let range = try XCTUnwrap(image.range(of: Data(from.utf8)), "the file declares \(from)")
        image.replaceSubrange(range, with: Data(to.utf8))
        try image.write(to: url)
    }
    let textKey = "local_id            TEXT PRIMARY KEY"
    let blobKey = "local_id            BLOB PRIMARY KEY"
    try declare(textKey, as: blobKey)
    try run("UPDATE photo_catalog SET local_id=\(key) WHERE local_id='\(localIdentifier)';")
    try declare(blobKey, as: textKey)
    XCTAssertEqual(try text("SELECT local_id FROM photo_catalog WHERE typeof(local_id)='integer';"), "\(key)")
}
