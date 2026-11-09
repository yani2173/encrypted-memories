import Foundation
import PhotosCore
import SQLite3
import UploadCore

struct TrashedSeriesRestoreRecord: Codable, Equatable, Sendable {
    struct Frame: Codable, Equatable, Sendable {
        let uid: PhotoUID
        let mainPhotoLinkID: String
        let trashTime: Int64
    }
    let generation: UUID
    let main: PhotoUID
    let mainTrashTime: Int64
    var frames: [Frame]
    var retryAt: Date
    var attempts: Int = 0
}

/// Account-owned duties. An unavailable journal never authorizes a remote mutation.
final class TrashedSeriesRestoreJournal: @unchecked Sendable {
    static let fileName = "trashed-series-restore-v1.sqlite"
    private let connection: SQLiteStoreConnection
    private var db: OpaquePointer? { connection.database }
    private static let schema = """
        CREATE TABLE restore_info(key TEXT PRIMARY KEY NOT NULL, value INTEGER NOT NULL);
        CREATE TABLE restore_duties(
            volume TEXT NOT NULL, main TEXT NOT NULL, generation TEXT NOT NULL, payload BLOB NOT NULL,
            PRIMARY KEY(volume, main));
        """

    private static let schemaVersionRow = SQLiteInfoTableVersion(
        table: "restore_info", version: 1, stampReplacesExistingRow: false)

    init?(url: URL, policy: LibraryDatabasePolicy = .conservative) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch { return nil }
        guard
            let handle = SQLiteStoreSchemaGate.openCurrentStore(
                at: url, schemaSQL: Self.schema, policy: policy,
                verifyVersion: Self.schemaVersionRow.verify, stampVersion: Self.schemaVersionRow.stamp)
        else { return nil }
        connection = SQLiteStoreConnection(database: handle)
    }

    /// Takes an already verified connection, also used for precise SQLite refusal tests.
    init(connection: SQLiteStoreConnection) { self.connection = connection }

    func close() { connection.close() }

    static var unavailable: UploadError { .backend(L10n.string("backup.error_local_state_unavailable")) }

    func records() throws -> [TrashedSeriesRestoreRecord] {
        try connection.withLock { try read() }
    }

    /// Every replacement is atomic. An unreadable existing duty prevents overwriting any record.
    func record(_ records: [TrashedSeriesRestoreRecord], mainTrashTimes: [PhotoUID: Int64] = [:]) throws {
        try transaction {
            for old in try read() {
                if let trash = mainTrashTimes[old.main], trash != old.mainTrashTime { try delete(old) }
            }
            for record in records {
                guard Self.isValid(record) else { throw Self.unavailable }
                try write(record)
            }
        }
    }

    /// A response owns only its generation and the exact captured duties that still exist.
    func update(_ record: TrashedSeriesRestoreRecord) throws {
        try transaction {
            guard let current = try read().first(where: { $0.main == record.main }),
                current.generation == record.generation
            else { return }
            var updated = record
            updated.frames = current.frames.filter { record.frames.contains($0) }
            if updated.frames.isEmpty {
                try delete(record)
            } else {
                guard Self.isValid(updated) else { throw Self.unavailable }
                try write(updated)
            }
        }
    }

    private static func isValid(_ record: TrashedSeriesRestoreRecord) -> Bool {
        !record.main.volumeID.isEmpty && !record.main.nodeID.isEmpty && !record.frames.isEmpty
            && record.retryAt.timeIntervalSince1970.isFinite && (0...32).contains(record.attempts)
            && Set(record.frames.map(\.uid)).count == record.frames.count
            && record.frames.allSatisfy {
                $0.uid.volumeID == record.main.volumeID && $0.uid != record.main
                    && $0.mainPhotoLinkID == record.main.nodeID
                    && TrashedRelatedPhotos.isWithinWindow($0.trashTime, of: record.mainTrashTime)
            }
    }

    private func read() throws -> [TrashedSeriesRestoreRecord] {
        guard db != nil else { throw Self.unavailable }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db, "SELECT volume, main, generation, payload FROM restore_duties ORDER BY volume, main;", -1,
                &statement, nil) == SQLITE_OK
        else { throw Self.unavailable }
        defer { sqlite3_finalize(statement) }
        var result: [TrashedSeriesRestoreRecord] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 3), sqlite3_column_bytes(statement, 3) > 0 else {
                throw Self.unavailable
            }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 3)))
            let record = try JSONDecoder().decode(TrashedSeriesRestoreRecord.self, from: data)
            guard Self.isValid(record), text(statement, 0) == record.main.volumeID,
                text(statement, 1) == record.main.nodeID, text(statement, 2) == record.generation.uuidString
            else { throw Self.unavailable }
            result.append(record)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw Self.unavailable }
        return result
    }

    private func delete(_ record: TrashedSeriesRestoreRecord) throws {
        try execute("DELETE FROM restore_duties WHERE volume=? AND main=? AND generation=?;") {
            try bind(record.main.volumeID, to: $0, at: 1)
            try bind(record.main.nodeID, to: $0, at: 2)
            try bind(record.generation.uuidString, to: $0, at: 3)
        }
    }

    private func write(_ record: TrashedSeriesRestoreRecord) throws {
        let data = try JSONEncoder().encode(record)
        try execute("INSERT OR REPLACE INTO restore_duties VALUES(?, ?, ?, ?);") { statement in
            try bind(record.main.volumeID, to: statement, at: 1)
            try bind(record.main.nodeID, to: statement, at: 2)
            try bind(record.generation.uuidString, to: statement, at: 3)
            let result = data.withUnsafeBytes {
                sqlite3_bind_blob(
                    statement, 4, $0.baseAddress, Int32($0.count), SQLiteStoreSchemaGate.transientDestructor)
            }
            guard result == SQLITE_OK else { throw Self.unavailable }
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try connection.withLock {
            guard db != nil else { throw Self.unavailable }
            let committed: Bool? = try SQLiteStoreSchemaGate.withDurableCommits(db) {
                guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { throw Self.unavailable }
                var committed = false
                defer { if !committed { connection.rollBack() } }
                try body()
                guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else { throw Self.unavailable }
                committed = true
                return true
            }
            guard committed == true else { throw Self.unavailable }
        }
    }

    private func execute(_ sql: String, bind: (OpaquePointer?) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.unavailable }
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.unavailable }
    }

    private func bind(_ text: String, to statement: OpaquePointer?, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, text, -1, SQLiteStoreSchemaGate.transientDestructor) == SQLITE_OK
        else {
            throw Self.unavailable
        }
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }
}
