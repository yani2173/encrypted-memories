import Foundation
import SQLite3

/// The step of a store check at which SQLite failed. A test names the step to supply its answer.
public enum SQLiteCheckStep: Sendable, Equatable {
    /// The read-only inspection of the file.
    case inspection
    /// The read-write inspection of the temporary copy.
    case copy
    /// The read-write verification of the exact schema.
    case verification
    /// SQLite's own integrity check of a cache.
    case quickCheck
}

/// SQLite's answer to a failed call on a connection: the extended result code and the operating-system error under
/// it. Read both right after the failure. SQLite overwrites them with the next call that touches the connection,
/// also with the `sqlite3_finalize` of a healthy statement that encloses the failed one.
struct SQLiteFailure: Equatable, Sendable {
    let code: Int32
    let systemErrno: Int32

    init(code: Int32, systemErrno: Int32) {
        self.code = code
        self.systemErrno = systemErrno
    }

    init(of db: OpaquePointer?) {
        self.init(code: sqlite3_extended_errcode(db), systemErrno: sqlite3_system_errno(db))
    }

    // Extended result codes that the SQLite3 module does not import (https://www.sqlite.org/rescode.html).
    static let shmOpen = SQLITE_IOERR | (18 << 8)
    static let shmSize = SQLITE_IOERR | (19 << 8)
    static let shmMap = SQLITE_IOERR | (21 << 8)

    /// True when the call that set this code failed. The result codes `SQLITE_OK`, `SQLITE_ROW` and `SQLITE_DONE`
    /// are no failure.
    var isError: Bool {
        let primary = code & 0xFF
        return primary != SQLITE_OK && primary != SQLITE_ROW && primary != SQLITE_DONE
    }

    /// True when the failure says nothing about the contents of the file, so the file must stay for a later open.
    ///
    /// - A full disk: `SQLITE_FULL`, an I/O error with `ENOSPC`, `SQLITE_IOERR_SHMSIZE`, or `SQLITE_CANTOPEN` with
    ///   `ENOSPC`.
    /// - A file that SQLite cannot open (`SQLITE_CANTOPEN`) or map (`SQLITE_IOERR_SHMOPEN`, `SQLITE_IOERR_SHMMAP`)
    ///   while the volume has no free block. On a full volume SQLite reports these codes with an `errno` of
    ///   `ENOENT` or `ESRCH`, not `ENOSPC`. `volumeIsFull` is read only for these codes, and an unknown answer
    ///   (`nil`) never keeps the file.
    ///
    /// The `SQLITE_CORRUPT` family, `SQLITE_NOTADB`, a bare `SQLITE_IOERR` that names no cause, `SQLITE_IOERR_WRITE`
    /// alone (SQLite reports a full file system as `SQLITE_FULL`), and every other code leave the file's earlier
    /// meaning.
    func keepsFile(volumeIsFull: () -> Bool?) -> Bool {
        switch code & 0xFF {
        case SQLITE_FULL:
            return true
        case SQLITE_IOERR:
            if code == Self.shmSize || systemErrno == ENOSPC { return true }
            return (code == Self.shmOpen || code == Self.shmMap) && volumeIsFull() == true
        case SQLITE_CANTOPEN:
            return systemErrno == ENOSPC || volumeIsFull() == true
        default:
            return false
        }
    }
}

/// How the gate asks whether a failed check says anything about the file. Production reads the connection and the
/// volume. A test supplies both answers per step, like the injected `copyItem` and `createDirectory`.
public struct SQLiteFailureProbe: Sendable {
    var failure: @Sendable (OpaquePointer?, SQLiteCheckStep) -> SQLiteFailure
    var volumeIsFull: @Sendable (URL, SQLiteCheckStep) -> Bool?

    public static let live = SQLiteFailureProbe(
        failure: { db, _ in SQLiteFailure(of: db) },
        volumeIsFull: { url, _ in DeviceStorage.volumeHasNoFreeBlocks(at: url) })

    /// Whether the failure of `db`'s last call keeps the file. A call that did not fail never does: the connection is
    /// read first, and only a real failure reaches the answer of `failure`. Call it before any other call on `db`.
    func keepsFile(after db: OpaquePointer?, step: SQLiteCheckStep) -> Bool {
        guard let db, SQLiteFailure(of: db).isError else { return false }
        return failure(db, step).keepsFile(volumeIsFull: {
            guard let path = sqlite3_db_filename(db, "main").map({ String(cString: $0) }), !path.isEmpty
            else { return nil }
            return volumeIsFull(URL(fileURLWithPath: path), step)
        })
    }

    /// Like `keepsFile(after:step:)`, and it closes `db`. The read comes first by construction, so no edit can close
    /// the connection before it.
    func keepsFile(closing db: OpaquePointer?, step: SQLiteCheckStep) -> Bool {
        defer { sqlite3_close(db) }
        return keepsFile(after: db, step: step)
    }
}
