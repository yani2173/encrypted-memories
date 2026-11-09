import Foundation
import PhotosCore
import SQLite3

/// The ordered local stages for a manual upload whose bytes already reached Proton.
///
/// The receipt is written at `.manifestPending` before the identity manifest is touched. A row
/// remains durable until the manifest, album membership, and queue terminal result settle in that
/// order. This table is independent from the Photo Library backup queue because manual uploads
/// have different identities, counters, and user-facing recovery semantics.
public enum UploadManualSettlementStage: String, Codable, Sendable, Equatable {
    case manifestPending
    case albumPending
    case terminal
}

/// The terminal queue result retained with a settled manual receipt.
public enum UploadManualSettlementTerminalState: String, Codable, Sendable, Equatable {
    case completed
    case failed
}

/// The cover intent needed when album attachment is replayed after a process restart.
public struct UploadManualSettlementCover: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case unchanged
        case firstUploaded
        case specific
    }

    public let kind: Kind
    public let specificPhoto: PhotoUID?

    public init(kind: Kind, specificPhoto: PhotoUID? = nil) {
        self.kind = kind
        self.specificPhoto = specificPhoto
    }

    public init(_ cover: UploadDestination.Cover) {
        switch cover {
        case .unchanged:
            self.init(kind: .unchanged)
        case .firstUploaded:
            self.init(kind: .firstUploaded)
        case .specific(let photo):
            self.init(kind: .specific, specificPhoto: photo)
        }
    }

    public var destinationCover: UploadDestination.Cover {
        switch kind {
        case .unchanged:
            return .unchanged
        case .firstUploaded:
            return .firstUploaded
        case .specific:
            return specificPhoto.map(UploadDestination.Cover.specific) ?? .unchanged
        }
    }
}

/// Destination metadata retained with a durable manual settlement.
public struct UploadManualSettlementDestination: Codable, Sendable, Equatable {
    public enum Target: String, Codable, Sendable, Equatable {
        case library
        case existingAlbum
        case newAlbum
    }

    public let target: Target
    public let targetID: String?
    public let targetName: String?
    public let cover: UploadManualSettlementCover

    public init(
        target: Target,
        targetID: String? = nil,
        targetName: String? = nil,
        cover: UploadManualSettlementCover = UploadManualSettlementCover(kind: .unchanged)
    ) {
        self.target = target
        self.targetID = targetID
        self.targetName = targetName
        self.cover = cover
    }

    public init(_ destination: UploadDestination) {
        switch destination.target {
        case .library:
            self.init(target: .library, cover: .init(destination.cover))
        case .existingAlbum(let id, let title):
            self.init(target: .existingAlbum, targetID: id, targetName: title, cover: .init(destination.cover))
        case .newAlbum(let name):
            self.init(target: .newAlbum, targetName: name, cover: .init(destination.cover))
        }
    }

    public func destination(resolvedAlbumID: String?) -> UploadDestination {
        let target: UploadDestination.Target
        switch self.target {
        case .library:
            target = .library
        case .existingAlbum:
            target = .existingAlbum(
                id: resolvedAlbumID ?? targetID ?? "",
                title: targetName ?? ""
            )
        case .newAlbum:
            target = .newAlbum(name: targetName ?? "")
        }
        return UploadDestination(target: target, cover: cover.destinationCover)
    }
}

/// Codable source and descriptor evidence captured before the irreversible transport result.
public struct UploadResourceDescriptorSnapshot: Codable, Sendable, Equatable {
    public let source: UploadSourceIdentity
    public let fileURL: URL
    public let filename: String
    public let fileSize: Int64
    public let modificationDate: Date
    public let precomputedSHA1Digest: Data?
    public let workIntentRawValue: Int

    public init(_ descriptor: UploadResourceDescriptor) {
        self.source = descriptor.source
        self.fileURL = descriptor.fileURL
        self.filename = descriptor.filename
        self.fileSize = descriptor.fileSize
        self.modificationDate = descriptor.modificationDate
        self.precomputedSHA1Digest = descriptor.precomputedSHA1Digest
        self.workIntentRawValue = descriptor.workIntent.rawValue
    }

    public var descriptor: UploadResourceDescriptor? {
        guard let workIntent = LibraryWorkIntent(rawValue: workIntentRawValue) else { return nil }
        return UploadResourceDescriptor(
            source: source,
            fileURL: fileURL,
            filename: filename,
            fileSize: fileSize,
            modificationDate: modificationDate,
            precomputedSHA1Digest: precomputedSHA1Digest,
            workIntent: workIntent
        )
    }
}

/// Durable evidence for one manual remote commit. The receipt remains authoritative over a local
/// cancellation once this row exists.
public struct UploadManualSettlementRecord: Codable, Sendable, Equatable {
    public let queueItemID: UploadQueueItemID
    public let ordinal: Int
    public let descriptor: UploadResourceDescriptorSnapshot
    public let identity: UploadIdentity
    public let receipt: UploadRemoteCommitReceipt
    public let displayName: String
    public let mediaType: String
    public let byteCount: Int64
    public let resolvedAlbumID: String?
    public let destination: UploadManualSettlementDestination
    public var stage: UploadManualSettlementStage
    public var terminalState: UploadManualSettlementTerminalState?
    public var lastError: String?
    public var updatedAt: Date

    public init(
        queueItemID: UploadQueueItemID,
        ordinal: Int = 0,
        descriptor: UploadResourceDescriptorSnapshot,
        identity: UploadIdentity,
        receipt: UploadRemoteCommitReceipt,
        displayName: String,
        mediaType: String,
        byteCount: Int64,
        resolvedAlbumID: String?,
        destination: UploadManualSettlementDestination,
        stage: UploadManualSettlementStage = .manifestPending,
        terminalState: UploadManualSettlementTerminalState? = nil,
        lastError: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.queueItemID = queueItemID
        self.ordinal = ordinal
        self.descriptor = descriptor
        self.identity = identity
        self.receipt = receipt
        self.displayName = displayName
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.resolvedAlbumID = resolvedAlbumID
        self.destination = destination
        self.stage = stage
        self.terminalState = terminalState
        self.lastError = lastError
        self.updatedAt = updatedAt
    }

    public var uploadedUID: PhotoUID {
        PhotoUID(volumeID: receipt.remoteVolumeID, nodeID: receipt.remoteLinkID)
    }

    public var isPending: Bool { stage != .terminal }

    /// Terminal is proven only with a recorded terminal state (#1104). Every durable
    /// terminal write records the state with the stage; a terminal stage without a state
    /// exists only in an in-memory copy whose terminal write failed, so callers must treat
    /// such a copy as unproven, never as settled.
    public var isProvenTerminal: Bool { stage == .terminal && terminalState != nil }
}

/// The result of one settlement-record read. `unreadable` separates a failed read from an
/// absent row (#1104): a caller must never mistake a store it could not read for an empty one,
/// even when a later operation has already healed the recorded failure.
public enum UploadManualSettlementReadOutcome: Sendable {
    case found(UploadManualSettlementRecord)
    case absent
    case unreadable
}

/// The result of one settlement-table sweep. An unreadable sweep is never an empty table (#1104).
public enum UploadManualSettlementListReadOutcome: Sendable {
    case records([UploadManualSettlementRecord])
    case unreadable
}

/// Synchronous, thread-safe store contract used by the actor-owned manual queue and its settlement
/// worker. Implementations must return `false` after an I/O failure. An empty failed read is never
/// interpreted as a drained queue.
public protocol UploadManualSettlementStoreProtocol: Sendable {
    func isOperational() -> Bool
    /// Healing health probe for gate checks (#1104): unlike `isOperational()`, this check lets a
    /// transiently recorded failure heal when the database answers again, so one failed write
    /// never refuses new work for the rest of the session. A lasting failure stays recorded.
    func isOperationalAllowingTransientRecovery() -> Bool
    /// True when the store cannot work again before a relaunch: the connection is closed, a
    /// transaction is open, or a recorded failure was not transient. Never probes the database.
    func hasLastingFailure() -> Bool
    @discardableResult
    func upsert(_ record: UploadManualSettlementRecord) -> Bool
    func readOutcome(for queueItemID: UploadQueueItemID) -> UploadManualSettlementReadOutcome
    func readAllOutcome() -> UploadManualSettlementListReadOutcome
    @discardableResult
    func remove(queueItemID: UploadQueueItemID) -> Bool
    func close()
}

/// Account-scoped SQLite persistence for manual post-commit settlement. The payload is encoded as
/// one versioned JSON value so adding evidence fields remains atomic and cannot leave a half-row.
public final class UploadManualSettlementStore: UploadManualSettlementStoreProtocol, @unchecked Sendable {
    public static let databaseFileName = "upload-manual-settlement-v1.sqlite"

    private static let schemaVersion = 1
    private let connection: SQLiteStoreConnection
    private var db: OpaquePointer? { connection.database }
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init?(url: URL, policy: LibraryDatabasePolicy = .conservative) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let handle = Self.open(url: url, policy: policy) else { return nil }
        connection = SQLiteStoreConnection(database: handle)
    }

    deinit { close() }

    public func isOperational() -> Bool { connection.isOperational(probeDatabase: false) }

    /// Healing health probe (#1104): probes the database file itself and forgets a recorded
    /// transient failure when it answers again. A probe failure is recorded as its own failure.
    public func isOperationalAllowingTransientRecovery() -> Bool {
        connection.isOperationalAfterTransientFailure()
    }

    public func hasLastingFailure() -> Bool {
        connection.withLock {
            guard let db, sqlite3_get_autocommit(db) != 0 else { return true }
            return connection.operationFailed && !connection.failuresAreTransient
        }
    }

    public func close() { connection.close() }

    /// Lets a transiently recorded connection heal before an operation runs, so one failed write never
    /// stops the whole session (#1104; the recovery check `PendingBackupStore` uses, #982). When the
    /// database answers a page read again, recorded transient failures are forgotten and the operation
    /// proceeds. A lasting failure, a closed connection and an open transaction stay recorded, and
    /// `isOperational()` keeps reporting them.
    private func allowTransientRecovery() {
        _ = connection.isOperationalAfterRecovery()
    }

    @discardableResult
    public func upsert(_ record: UploadManualSettlementRecord) -> Bool {
        allowTransientRecovery()
        return connection.withLock {
            // A closed handle or an outside transaction is a lasting condition with no SQLite code.
            guard let db, sqlite3_get_autocommit(db) != 0 else {
                connection.markFailed()
                return false
            }
            // Keep an already recorded failure exactly as it is; marking again would turn a transient
            // latch into a lasting one.
            guard !connection.operationFailed else { return false }
            guard let payload = try? encoder.encode(record) else {
                connection.markFailed()
                return false
            }
            var statement: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    """
                    INSERT INTO manual_upload_settlement(queue_item_id, stage, payload, updated_at)
                    VALUES(?,?,?,?)
                    ON CONFLICT(queue_item_id) DO UPDATE SET
                      stage=excluded.stage, payload=excluded.payload, updated_at=excluded.updated_at;
                    """,
                    -1,
                    &statement,
                    nil
                ) == SQLITE_OK
            else {
                connection.markFailed(resultCode: sqlite3_extended_errcode(db))
                return false
            }
            defer { sqlite3_finalize(statement) }
            // A failed bind leaves its parameter NULL; it records the failure and fails the write (#1194).
            do {
                try connection.bindText(statement, 1, record.queueItemID.uuidString)
                try connection.bindText(statement, 2, record.stage.rawValue)
                try connection.bindText(statement, 3, String(decoding: payload, as: UTF8.self))
            } catch {
                return false
            }
            sqlite3_bind_double(statement, 4, record.updatedAt.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                connection.markFailed(resultCode: sqlite3_extended_errcode(db))
                return false
            }
            return true
        }
    }

    public func readOutcome(for queueItemID: UploadQueueItemID) -> UploadManualSettlementReadOutcome {
        allowTransientRecovery()
        return connection.withLock {
            guard let db, sqlite3_get_autocommit(db) != 0 else {
                connection.markFailed()
                return .unreadable
            }
            guard !connection.operationFailed else { return .unreadable }
            var statement: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    "SELECT payload FROM manual_upload_settlement WHERE queue_item_id=?;",
                    -1,
                    &statement,
                    nil
                ) == SQLITE_OK
            else {
                connection.markFailed(resultCode: sqlite3_extended_errcode(db))
                return .unreadable
            }
            defer { sqlite3_finalize(statement) }
            // A key that does not bind is no proof that the row is absent (#1194).
            do { try connection.bindText(statement, 1, queueItemID.uuidString) } catch { return .unreadable }
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else {
                if result != SQLITE_DONE {
                    connection.markFailed(resultCode: sqlite3_extended_errcode(db))
                    return .unreadable
                }
                return .absent
            }
            guard let payload = columnText(statement, 0),
                let data = payload.data(using: .utf8),
                let record = try? decoder.decode(UploadManualSettlementRecord.self, from: data)
            else {
                connection.markFailed()
                return .unreadable
            }
            return .found(record)
        }
    }

    public func readAllOutcome() -> UploadManualSettlementListReadOutcome {
        guard let records = readRecords(whereClause: nil) else { return .unreadable }
        return .records(records)
    }

    @discardableResult
    public func remove(queueItemID: UploadQueueItemID) -> Bool {
        allowTransientRecovery()
        return connection.withLock {
            guard let db, sqlite3_get_autocommit(db) != 0 else {
                connection.markFailed()
                return false
            }
            guard !connection.operationFailed else { return false }
            var statement: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    "DELETE FROM manual_upload_settlement WHERE queue_item_id=?;",
                    -1,
                    &statement,
                    nil
                ) == SQLITE_OK
            else {
                connection.markFailed(resultCode: sqlite3_extended_errcode(db))
                return false
            }
            defer { sqlite3_finalize(statement) }
            // A key that does not bind removes nothing; that is no successful removal (#1194).
            do { try connection.bindText(statement, 1, queueItemID.uuidString) } catch { return false }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                connection.markFailed(resultCode: sqlite3_extended_errcode(db))
                return false
            }
            return true
        }
    }

    private func readRecords(whereClause: String?) -> [UploadManualSettlementRecord]? {
        allowTransientRecovery()
        return connection.withLock {
            guard let db, sqlite3_get_autocommit(db) != 0 else {
                connection.markFailed()
                return nil
            }
            guard !connection.operationFailed else { return nil }
            var statement: OpaquePointer?
            let suffix = whereClause.map { " WHERE \($0)" } ?? ""
            guard
                sqlite3_prepare_v2(
                    db,
                    "SELECT payload FROM manual_upload_settlement\(suffix) ORDER BY updated_at ASC;",
                    -1,
                    &statement,
                    nil
                ) == SQLITE_OK
            else {
                connection.markFailed(resultCode: sqlite3_extended_errcode(db))
                return nil
            }
            defer { sqlite3_finalize(statement) }
            var records: [UploadManualSettlementRecord] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                guard let payload = columnText(statement, 0),
                    let data = payload.data(using: .utf8),
                    let record = try? decoder.decode(UploadManualSettlementRecord.self, from: data)
                else {
                    connection.markFailed()
                    return nil
                }
                records.append(record)
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                connection.markFailed(resultCode: sqlite3_extended_errcode(db))
                return nil
            }
            return records
        }
    }

    private static func open(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        let schema = """
            CREATE TABLE IF NOT EXISTS manual_upload_settlement_info(
              key TEXT PRIMARY KEY,
              value INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS manual_upload_settlement(
              queue_item_id TEXT PRIMARY KEY,
              stage TEXT NOT NULL,
              payload TEXT NOT NULL,
              updated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS manual_upload_settlement_stage_idx
              ON manual_upload_settlement(stage, updated_at);
            """

        return SQLiteStoreSchemaGate.openCurrentStore(
            at: url,
            schemaSQL: schema,
            policy: policy,
            verifyVersion: verifyVersion,
            stampVersion: stampVersion
        )
    }

    private static func verifyVersion(_ db: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                "SELECT value FROM manual_upload_settlement_info WHERE key='schema';",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        else { return false }
        var onDisk: Int?
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { onDisk = Int(sqlite3_column_int(statement, 0)) }
        sqlite3_finalize(statement)
        return result == SQLITE_ROW && onDisk == schemaVersion
    }

    private static func stampVersion(_ db: OpaquePointer?) -> Bool {
        return sqlite3_exec(
            db,
            "INSERT INTO manual_upload_settlement_info(key, value) VALUES('schema', \(schemaVersion)) "
                + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
            nil,
            nil,
            nil
        ) == SQLITE_OK
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }
}
