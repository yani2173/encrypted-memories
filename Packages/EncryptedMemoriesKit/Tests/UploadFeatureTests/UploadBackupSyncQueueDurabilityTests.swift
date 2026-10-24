import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

/// A queue row of a new or changed photo must survive a power loss before the catalog marks the photo as seen (#352).
/// A SQLite VFS that wraps the default VFS records every sync of a WAL file, so the tests see what reaches the disk.
final class UploadBackupSyncQueueDurabilityTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-backup-sync-queue-durability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try WALSyncRecorder.register()
    }

    override func tearDownWithError() throws {
        WALSyncRecorder.unregister()
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testQueueInsertsSyncTheWALBeforeTheyReturnAndStateChangesDoNot() throws {
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        defer { store.close() }
        // The first commit after a checkpoint also syncs the WAL header, at any synchronous level.
        XCTAssertTrue(store.upsert(entry("first")))

        WALSyncRecorder.reset()
        XCTAssertTrue(store.upsertBatch([entry("A"), entry("B")]))
        assertFullSyncs(WALSyncRecorder.syncs(ofWALFor: queueURL), "upsertBatch")

        WALSyncRecorder.reset()
        XCTAssertTrue(store.upsert(entry("C")))
        assertFullSyncs(WALSyncRecorder.syncs(ofWALFor: queueURL), "upsert")

        WALSyncRecorder.reset()
        XCTAssertEqual(store.claimRunnable(limit: 1, claimedAt: Date(timeIntervalSince1970: 2_000)).count, 1)
        XCTAssertTrue(
            store.updateState(
                source: source("A"), revision: revision, state: .uploading, attempts: 1, lastError: nil,
                updatedAt: Date(timeIntervalSince1970: 2_001)))
        XCTAssertEqual(
            WALSyncRecorder.syncs(ofWALFor: queueURL), [], "state changes keep synchronous=NORMAL after an insert")
    }

    func testRecoveryInsertsAndMissingSourceDiscardsSyncTheWALBeforeTheyReturn() throws {
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        defer { store.close() }
        XCTAssertTrue(store.upsert(entry("warmup")))
        WALSyncRecorder.reset()
        XCTAssertTrue(store.insertMissingSources([entry("A"), entry("B")]))
        assertFullSyncs(WALSyncRecorder.syncs(ofWALFor: queueURL), "insertMissingSources")
        WALSyncRecorder.reset()
        XCTAssertTrue(store.removeMissingSource(source: source("A"), revision: revision))
        assertFullSyncs(WALSyncRecorder.syncs(ofWALFor: queueURL), "removeMissingSource")
        XCTAssertEqual(store.missingSourceDiscardGeneration(), 1)
    }

    func testDurableCommitsRestoreTheConnectionSettings() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(tempDir.appendingPathComponent("plain.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", nil, nil, nil), SQLITE_OK)

        let inside = SQLiteStoreSchemaGate.withDurableCommits(db) {
            (Self.pragma("synchronous", in: db), Self.pragma("fullfsync", in: db))
        }
        XCTAssertEqual(inside?.0, 2, "FULL")
        XCTAssertEqual(inside?.1, 1)
        XCTAssertEqual(Self.pragma("synchronous", in: db), 1, "NORMAL")
        XCTAssertEqual(Self.pragma("fullfsync", in: db), 0)

        // SQLite refuses the change inside a transaction, so the body does not run.
        XCTAssertEqual(sqlite3_exec(db, "BEGIN;", nil, nil, nil), SQLITE_OK)
        var ran = false
        XCTAssertNil(SQLiteStoreSchemaGate.withDurableCommits(db) { ran = true })
        XCTAssertFalse(ran)
        XCTAssertEqual(sqlite3_exec(db, "COMMIT;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(Self.pragma("synchronous", in: db), 1, "NORMAL")
    }

    private var queueURL: URL { tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName) }
    private let revision = UploadBackupRevision(date: Date(timeIntervalSince1970: 1_000))

    private func source(_ id: String) -> UploadSourceIdentity {
        UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id)
    }

    private func entry(_ id: String) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: source(id), revision: revision, originalFilename: "\(id).heic", byteCount: 1, state: .discovered,
            updatedAt: Date(timeIntervalSince1970: 1_000))
    }

    /// A commit syncs the WAL with `F_FULLFSYNC`, which SQLite requests as `SQLITE_SYNC_FULL`.
    private func assertFullSyncs(
        _ flags: [Int32], _ operation: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(flags.isEmpty, "\(operation) returned before the WAL was synced", file: file, line: line)
        XCTAssertEqual(
            flags.map { $0 & 0x0F }, flags.map { _ in SQLITE_SYNC_FULL }, "\(operation) synced without F_FULLFSYNC",
            file: file, line: line)
    }

    private static func pragma(_ name: String, in db: OpaquePointer?) -> Int32? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA \(name);", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int(statement, 0)
    }
}

/// Registers a default VFS that forwards to the system VFS. A WAL file it opens gets a copy of its method table with
/// `xSync` and `xClose` replaced: `xSync` records the file and the sync flags, and `xClose` restores the table.
private enum WALSyncRecorder {
    private struct Sync {
        let path: String
        let flags: Int32
    }

    private struct OpenFile {
        let path: String
        let methods: UnsafePointer<sqlite3_io_methods>
        let table: UnsafeMutablePointer<sqlite3_io_methods>
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [Sync] = []
    nonisolated(unsafe) private static var openFiles: [UnsafeMutableRawPointer: OpenFile] = [:]
    nonisolated(unsafe) private static var base: UnsafeMutablePointer<sqlite3_vfs>?
    nonisolated(unsafe) private static var shim: UnsafeMutablePointer<sqlite3_vfs>?

    static func register() throws {
        if shim == nil {
            guard let system = sqlite3_vfs_find(nil) else { throw XCTSkip("SQLite has no default VFS") }
            base = system
            var vfs = system.pointee
            vfs.zName = UnsafePointer(strdup("wal-sync-recorder"))
            vfs.pNext = nil
            vfs.xOpen = { _, name, file, flags, outFlags in
                guard let base = WALSyncRecorder.base, let file else { return SQLITE_ERROR }
                let result = base.pointee.xOpen(base, name, file, flags, outFlags)
                guard result == SQLITE_OK, flags & SQLITE_OPEN_WAL != 0, let name,
                    let methods = file.pointee.pMethods
                else { return result }
                WALSyncRecorder.wrap(file, path: String(cString: name), methods: methods)
                return result
            }
            let pointer = UnsafeMutablePointer<sqlite3_vfs>.allocate(capacity: 1)
            pointer.initialize(to: vfs)
            shim = pointer
        }
        guard sqlite3_vfs_register(shim, 1) == SQLITE_OK else { throw XCTSkip("the VFS could not be registered") }
        reset()
    }

    /// Call after every connection that the VFS opened is closed.
    static func unregister() {
        sqlite3_vfs_unregister(shim)
        reset()
    }

    static func reset() {
        lock.withLock { recorded = [] }
    }

    /// The flags of each sync of the WAL of `database`, oldest first.
    static func syncs(ofWALFor database: URL) -> [Int32] {
        let suffix = database.lastPathComponent + "-wal"
        let directory = database.deletingLastPathComponent().lastPathComponent
        return lock.withLock {
            recorded.filter { $0.path.hasSuffix(suffix) && $0.path.contains(directory) }.map(\.flags)
        }
    }

    private static func wrap(
        _ file: UnsafeMutablePointer<sqlite3_file>, path: String, methods: UnsafePointer<sqlite3_io_methods>
    ) {
        let table = UnsafeMutablePointer<sqlite3_io_methods>.allocate(capacity: 1)
        table.initialize(to: methods.pointee)
        table.pointee.xSync = { file, flags in
            guard let file, let open = WALSyncRecorder.openFile(file) else { return SQLITE_ERROR }
            WALSyncRecorder.lock.withLock { WALSyncRecorder.recorded.append(Sync(path: open.path, flags: flags)) }
            return open.methods.pointee.xSync(file, flags)
        }
        table.pointee.xClose = { file in
            guard let file, let open = WALSyncRecorder.forget(file) else { return SQLITE_ERROR }
            file.pointee.pMethods = open.methods
            let result = open.methods.pointee.xClose(file)
            open.table.deinitialize(count: 1)
            open.table.deallocate()
            return result
        }
        let open = OpenFile(path: path, methods: methods, table: table)
        lock.withLock { openFiles[UnsafeMutableRawPointer(file)] = open }
        file.pointee.pMethods = UnsafePointer(table)
    }

    private static func forget(_ file: UnsafeMutablePointer<sqlite3_file>) -> OpenFile? {
        lock.withLock { openFiles.removeValue(forKey: UnsafeMutableRawPointer(file)) }
    }

    private static func openFile(_ file: UnsafeMutablePointer<sqlite3_file>) -> OpenFile? {
        lock.withLock { openFiles[UnsafeMutableRawPointer(file)] }
    }
}
