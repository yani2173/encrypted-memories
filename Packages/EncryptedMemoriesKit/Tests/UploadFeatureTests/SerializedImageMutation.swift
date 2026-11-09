import Foundation
import SQLite3
import XCTest

@testable import PhotosCore

/// Test support for #1004 recovery tests: mutates a store connection's own database image. An external write to
/// the database file stays invisible to an open connection's page cache, so a mutation that the next
/// `sqlite3_step` must see travels through `sqlite3_serialize` + `sqlite3_deserialize` on the store's connection
/// instead. The swap keeps the connection's recorded failure state, and the on-disk file stays untouched.
enum SerializedImageMutation {
    enum MutationError: Error {
        case serializeFailed
        case deserializeFailed(Int32)
        case openFailed
    }

    /// Replaces the connection's database image with a mutated copy of itself. Must be called OUTSIDE
    /// `connection.withLock` (it takes the lock itself) and outside a transaction; the health probe
    /// (`sqlite_schema`) stays readable unless the mutation breaks it, and `BEGIN IMMEDIATE` still succeeds,
    /// so a failed keyed step fails on its own.
    ///
    /// The callback receives a mutable `[UInt8]` buffer representing the serialized database image. After the callback
    /// returns, the header write/read version bytes (offsets 18/19) are forced to legacy journal mode (1) to avoid
    /// CANTOPEN on deserialization (WAL images expect a `-wal` file), and the mutated image is deserialized onto
    /// the same connection with `FREEONCLOSE`. Writes then fail rc=8 (readonly), but keyed reads still prepare and
    /// fail at step if they touch the corrupted pages.
    static func install(
        on connection: SQLiteStoreConnection,
        _ mutating: (inout [UInt8]) throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try connection.withLock {
            guard let db = connection.database else {
                throw MutationError.openFailed
            }

            // Ensure all data is flushed to the file before we serialize.
            XCTAssertEqual(
                sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil), SQLITE_OK,
                "\(file):\(line) checkpoint must succeed")

            // Serialize the live image.
            var size = Int64(0)
            guard let serialized = sqlite3_serialize(db, "main", &size, 0), size > 0 else {
                throw MutationError.serializeFailed
            }

            // Copy into a mutable array.
            var image = [UInt8](
                UnsafeMutableBufferPointer(start: serialized, count: Int(size)))
            sqlite3_free(serialized)

            // Apply the user's mutation.
            try `mutating`(&image)

            // Force legacy journal mode in the header to avoid CANTOPEN on deserialization.
            // WAL-mode images have bytes 18/19 = 2; setting them to 1 makes the image self-contained.
            // If the image was already legacy, this is a no-op.
            if image.count >= 20 {
                image[18] = 1
                image[19] = 1
            }

            // Allocate a pointer buffer and copy the mutated image.
            let buf = UnsafeMutableRawPointer.allocate(byteCount: image.count, alignment: 64)
            image.withUnsafeBytes { memcpy(buf, $0.baseAddress!, image.count) }

            // Deserialize onto the same connection with FREEONCLOSE so SQLite frees the buffer.
            let rc = sqlite3_deserialize(
                db, "main", buf, Int64(image.count), Int64(image.count),
                UInt32(SQLITE_DESERIALIZE_FREEONCLOSE))
            guard rc == SQLITE_OK else {
                buf.deallocate()
                throw MutationError.deserializeFailed(rc)
            }
        }
    }

    /// Convenience: zeroes the page of a named index root, so a keyed lookup on that index still prepares
    /// but its step answers SQLITE_CORRUPT. Returns the zeroed root page number. Must be called OUTSIDE
    /// `connection.withLock`.
    static func zeroIndexRootPage(on connection: SQLiteStoreConnection, indexName: String) throws -> Int {
        var rootPage: Int?
        var pageSize: Int?
        connection.withLock {
            guard let db = connection.database else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            // Get page size.
            var psStmt: OpaquePointer?
            defer { sqlite3_finalize(psStmt) }
            guard sqlite3_prepare_v2(db, "PRAGMA page_size;", -1, &psStmt, nil) == SQLITE_OK,
                sqlite3_step(psStmt) == SQLITE_ROW
            else { return }
            pageSize = Int(sqlite3_column_int64(psStmt, 0))

            // Get index root page.
            let sql = "SELECT rootpage FROM sqlite_schema WHERE name='\(indexName)';"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                sqlite3_step(stmt) == SQLITE_ROW
            else { return }
            rootPage = Int(sqlite3_column_int64(stmt, 0))
        }
        guard let root = rootPage, let size = pageSize else {
            preconditionFailure("Could not read page_size or index root for '\(indexName)'")
        }

        try install(on: connection) { image in
            let start = size * (root - 1)
            // Zero the entire page (bounds-checked).
            let end = min(start + size, image.count)
            for i in start..<end {
                image[i] = 0
            }
        }

        return root
    }
}
