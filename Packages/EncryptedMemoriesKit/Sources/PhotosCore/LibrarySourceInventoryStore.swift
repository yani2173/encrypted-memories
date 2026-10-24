import CryptoKit
import Foundation
import SQLite3

public enum LibrarySourceInventoryStoreError: Error, Sendable, Equatable {
    case openFailed
    case alreadyOwned
    case corruptData
    case staleSession
    case staleWriteLease
}

public struct LibrarySourceInventorySaveResult: Sendable, Equatable {
    public let changedSources: Int
    public let changedItems: Int
    public let removedSources: Int
    public let removedItems: Int

    public var changedRows: Int {
        changedSources + changedItems + removedSources + removedItems
    }
}

/// Encrypted, normalized persistence for source inventories.
///
/// This store is one rebuildable remote-projection database. It never owns timeline, user source
/// choices, invitations, edits, ML artifacts, or operational upload state. Its schema has one rule:
/// an exact version opens; every incompatible or corrupt local database is closed, deleted with its
/// WAL/SHM sidecars, and rebuilt. There is no migration path.
///
/// Stable keyed hashes are the only identifiers visible to SQLite. Source and item payloads use
/// AES-GCM with account- and row-bound additional authenticated data. A refresh performs indexed
/// digest probes and writes only changed rows; an anti-join removes vanished rows without replacing
/// the full database.
public final class LibrarySourceInventoryStore: @unchecked Sendable {
    private enum OpenResult {
        case opened
        case incompatible
        case failed
    }

    public struct SessionLease: Hashable, Sendable {
        fileprivate let epoch: LibrarySourceEpoch
        fileprivate let generation: UInt64
    }

    public struct WriteLease: Hashable, Sendable {
        fileprivate let epoch: LibrarySourceEpoch
        fileprivate let sessionGeneration: UInt64
        fileprivate let sequence: UInt64
    }

    private struct StoredSource: Codable {
        let id: SourceID
        let capabilities: LibrarySourceCapabilities
        let precedence: Int
        let accessState: AccessState
        let authority: SourceInventoryAuthority
        let validationToken: String?

        init(inventory: LibrarySourceInventory) {
            id = inventory.source.id
            capabilities = inventory.source.capabilities
            precedence = inventory.source.precedence
            accessState = inventory.accessState
            authority = inventory.authority
            validationToken = inventory.validationToken
        }

        var source: LibrarySource {
            LibrarySource(
                id: id,
                capabilities: capabilities,
                precedence: precedence,
                isIncluded: false
            )
        }
    }

    private struct PreparedItemRow {
        let itemKey: Data
        let digest: Data
        let changedPayload: Data?
    }

    private struct PreparedSourceRow {
        let sourceKey: Data
        let digest: Data
        let changedPayload: Data?
        let isAuthoritative: Bool
        let items: [PreparedItemRow]
    }

    public static let databaseFileName = "library-source-inventory-v1.sqlite"
    private static let schemaVersion: Int32 = 1
    private static let cipherNamespace = "EncryptedMemories.library-source-inventory.v1"

    private let fileURL: URL
    private let accountUID: String
    private let encryptionKey: SymmetricKey
    private let indexKey: SymmetricKey
    private let policy: LibraryDatabasePolicy
    private let queue: DispatchQueue
    private let transient = SQLiteStoreSchemaGate.transientDestructor
    private let ownerID = UUID()

    private var db: OpaquePointer?
    private var ownsFile = false
    private var activeEpoch: LibrarySourceEpoch?
    private var sessionGeneration: UInt64 = 0
    private var nextWriteSequence: UInt64 = 0
    private var lastCommittedWriteSequence: UInt64?
    private var lastCommittedSnapshotSignature: LibrarySourcePersistenceSignature?

    public init(
        directory: URL,
        accountUID: String,
        encryptionKey: SymmetricKey,
        policy: LibraryDatabasePolicy = .conservative
    ) {
        fileURL = directory.appendingPathComponent(Self.databaseFileName, isDirectory: false)
        self.accountUID = accountUID
        self.encryptionKey = encryptionKey
        indexKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: encryptionKey,
            salt: Data(Self.cipherNamespace.utf8),
            info: Data("account=\(accountUID)|purpose=keyed-index".utf8),
            outputByteCount: 32
        )
        self.policy = policy
        queue = DispatchQueue(
            label: "app.encryptedmemories.library-source-inventory-store",
            qos: .utility
        )
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
        if ownsFile {
            LibrarySourceInventoryOwnerRegistry.shared.release(fileURL, ownerID: ownerID)
        }
    }

    public static func databaseFileNames() -> [String] {
        [databaseFileName, databaseFileName + "-wal", databaseFileName + "-shm"]
    }

    /// Starts one graph-owned persistence session and invalidates leases from older graph lifetimes.
    public func activate(for epoch: LibrarySourceEpoch) async throws -> SessionLease {
        try await perform {
            if !self.ownsFile {
                guard
                    LibrarySourceInventoryOwnerRegistry.shared.acquire(
                        self.fileURL,
                        ownerID: self.ownerID
                    )
                else {
                    throw LibrarySourceInventoryStoreError.alreadyOwned
                }
                self.ownsFile = true
            }
            guard self.openVerified() else {
                LibrarySourceInventoryOwnerRegistry.shared.release(
                    self.fileURL,
                    ownerID: self.ownerID
                )
                self.ownsFile = false
                throw LibrarySourceInventoryStoreError.openFailed
            }
            self.sessionGeneration &+= 1
            self.activeEpoch = epoch
            self.nextWriteSequence = 0
            self.lastCommittedWriteSequence = nil
            self.lastCommittedSnapshotSignature = nil
            return SessionLease(epoch: epoch, generation: self.sessionGeneration)
        }
    }

    /// Captures an ordered write. A write becomes stale only after a later sequence commits.
    public func captureWriteLease(using session: SessionLease) async throws -> WriteLease {
        try await perform {
            try self.validate(session)
            self.nextWriteSequence &+= 1
            return WriteLease(
                epoch: session.epoch,
                sessionGeneration: session.generation,
                sequence: self.nextWriteSequence
            )
        }
    }

    /// Loads every inventory with two ordered scans. Runtime authority is downgraded by the graph.
    public func load(using session: SessionLease) async throws -> [LibrarySourceInventory] {
        try await perform {
            try self.validate(session)
            do {
                guard let db = self.db else {
                    throw LibrarySourceInventoryStoreError.openFailed
                }

                var sourceStatement: OpaquePointer?
                guard
                    sqlite3_prepare_v2(
                        db,
                        "SELECT source_key, payload FROM source_inventory ORDER BY source_key;",
                        -1,
                        &sourceStatement,
                        nil
                    ) == SQLITE_OK
                else {
                    throw Self.readError(sqlite3_errcode(db))
                }
                defer { sqlite3_finalize(sourceStatement) }

                var storedSources: [(key: Data, value: StoredSource)] = []
                var sourceIndexByKey: [Data: Int] = [:]
                var sourceStep = sqlite3_step(sourceStatement)
                while sourceStep == SQLITE_ROW {
                    guard let sourceKey = Self.columnData(sourceStatement, 0),
                        let payload = Self.columnData(sourceStatement, 1)
                    else { throw LibrarySourceInventoryStoreError.corruptData }
                    let stored: StoredSource = try self.open(
                        payload,
                        domain: "source",
                        rowKey: sourceKey
                    )
                    guard self.sourceKey(for: stored.source.id) == sourceKey else {
                        throw LibrarySourceInventoryStoreError.corruptData
                    }
                    sourceIndexByKey[sourceKey] = storedSources.count
                    storedSources.append((sourceKey, stored))
                    sourceStep = sqlite3_step(sourceStatement)
                }
                guard sourceStep == SQLITE_DONE else { throw Self.readError(sourceStep) }

                var itemsBySource = Array(repeating: [LibrarySourceItem](), count: storedSources.count)
                var itemStatement: OpaquePointer?
                guard
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT source_key, item_key, payload
                        FROM source_item
                        ORDER BY source_key, item_key;
                        """,
                        -1,
                        &itemStatement,
                        nil
                    ) == SQLITE_OK
                else {
                    throw Self.readError(sqlite3_errcode(db))
                }
                defer { sqlite3_finalize(itemStatement) }

                var itemStep = sqlite3_step(itemStatement)
                while itemStep == SQLITE_ROW {
                    guard let sourceKey = Self.columnData(itemStatement, 0),
                        let itemKey = Self.columnData(itemStatement, 1),
                        let payload = Self.columnData(itemStatement, 2),
                        let sourceIndex = sourceIndexByKey[sourceKey]
                    else { throw LibrarySourceInventoryStoreError.corruptData }
                    let item: LibrarySourceItem = try self.open(
                        payload,
                        domain: "item",
                        rowKey: sourceKey + itemKey
                    )
                    guard self.itemKey(for: item.uid) == itemKey else {
                        throw LibrarySourceInventoryStoreError.corruptData
                    }
                    itemsBySource[sourceIndex].append(item)
                    itemStep = sqlite3_step(itemStatement)
                }
                guard itemStep == SQLITE_DONE else { throw Self.readError(itemStep) }

                let inventories = storedSources.enumerated().map { index, stored in
                    Self.canonicalInventory(
                        LibrarySourceInventory(
                            source: stored.value.source,
                            accessState: stored.value.accessState,
                            authority: stored.value.authority,
                            items: itemsBySource[index],
                            validationToken: stored.value.validationToken
                        ))
                }.sorted { lhs, rhs in
                    lhs.source.id.rawValue.utf8.lexicographicallyPrecedes(
                        rhs.source.id.rawValue.utf8
                    )
                }
                try LibrarySourceInventoryValidator.validate(inventories)
                return inventories
            } catch LibrarySourceInventoryStoreError.corruptData {
                try self.resetCorruptStoreLocked()
                return []
            } catch is LibrarySourceInventoryValidationError {
                try self.resetCorruptStoreLocked()
                return []
            }
        }
    }

    /// Reconciles one complete snapshot with changed-row writes and authoritative anti-join sweeps.
    @discardableResult
    public func save(
        _ inventories: [LibrarySourceInventory],
        sourceSetAuthority: SourceSetAuthority,
        using lease: WriteLease
    ) async throws -> LibrarySourceInventorySaveResult {
        try await save(
            inventories,
            sourceSetAuthority: sourceSetAuthority,
            persistenceSignature: nil,
            using: lease
        )
    }

    /// Graph-owned save path with an exact, session-local snapshot identity. A repeated identity
    /// advances write ordering without encoding, encrypting, probing, or writing every item again.
    package func save(
        _ inventories: [LibrarySourceInventory],
        sourceSetAuthority: SourceSetAuthority,
        persistenceSignature: LibrarySourcePersistenceSignature,
        using lease: WriteLease
    ) async throws -> LibrarySourceInventorySaveResult {
        try await save(
            inventories,
            sourceSetAuthority: sourceSetAuthority,
            persistenceSignature: Optional(persistenceSignature),
            using: lease
        )
    }

    private func save(
        _ inventories: [LibrarySourceInventory],
        sourceSetAuthority: SourceSetAuthority,
        persistenceSignature: LibrarySourcePersistenceSignature?,
        using lease: WriteLease
    ) async throws -> LibrarySourceInventorySaveResult {
        try await perform {
            try self.validate(lease)
            if let persistenceSignature,
                persistenceSignature == self.lastCommittedSnapshotSignature
            {
                self.lastCommittedWriteSequence = lease.sequence
                return LibrarySourceInventorySaveResult(
                    changedSources: 0,
                    changedItems: 0,
                    removedSources: 0,
                    removedItems: 0
                )
            }
            try LibrarySourceInventoryValidator.validate(inventories)
            guard let db = self.db else {
                throw LibrarySourceInventoryStoreError.openFailed
            }
            let ordered =
                inventories
                .map(Self.canonicalInventory)
                .sorted { lhs, rhs in
                    lhs.source.id.rawValue.utf8.lexicographicallyPrecedes(
                        rhs.source.id.rawValue.utf8
                    )
                }
            // Encode, hash, and encrypt before acquiring SQLite's write lock. The transaction then
            // performs only indexed probes and changed-row writes.
            let statements = try LibrarySourceInventorySaveStatements(db: db)
            let preparedRows = try ordered.map { try self.prepare($0, statements: statements) }

            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
                throw LibrarySourceInventoryStoreError.openFailed
            }
            do {
                guard
                    sqlite3_exec(
                        db,
                        """
                        DELETE FROM incoming_source;
                        DELETE FROM incoming_authoritative_source;
                        DELETE FROM incoming_item;
                        """,
                        nil,
                        nil,
                        nil
                    ) == SQLITE_OK
                else {
                    throw LibrarySourceInventoryStoreError.corruptData
                }
                var changedSources = 0
                var changedItems = 0
                for row in preparedRows {
                    try Self.executeBlobStatement(
                        statements.incomingSource,
                        bindings: [row.sourceKey],
                        transient: self.transient
                    )
                    if row.isAuthoritative {
                        try Self.executeBlobStatement(
                            statements.incomingAuthoritativeSource,
                            bindings: [row.sourceKey],
                            transient: self.transient
                        )
                    }
                    if let changedPayload = row.changedPayload {
                        try Self.executeBlobStatement(
                            statements.upsertSource,
                            bindings: [row.sourceKey, row.digest, changedPayload],
                            transient: self.transient
                        )
                        changedSources += 1
                    }
                    for item in row.items {
                        try Self.executeBlobStatement(
                            statements.incomingItem,
                            bindings: [row.sourceKey, item.itemKey],
                            transient: self.transient
                        )
                        if let changedPayload = item.changedPayload {
                            try Self.executeBlobStatement(
                                statements.upsertItem,
                                bindings: [row.sourceKey, item.itemKey, item.digest, changedPayload],
                                transient: self.transient
                            )
                            changedItems += 1
                        }
                    }
                }

                let beforeItems = sqlite3_total_changes(db)
                guard
                    sqlite3_exec(
                        db,
                        """
                        DELETE FROM source_item
                        WHERE EXISTS (
                          SELECT 1 FROM incoming_authoritative_source a
                          WHERE a.source_key = source_item.source_key
                        )
                        AND NOT EXISTS (
                          SELECT 1 FROM incoming_item i
                          WHERE i.source_key = source_item.source_key
                            AND i.item_key = source_item.item_key
                        );
                        """,
                        nil,
                        nil,
                        nil
                    ) == SQLITE_OK
                else {
                    throw LibrarySourceInventoryStoreError.corruptData
                }
                var removedItems = Int(sqlite3_total_changes(db) - beforeItems)

                var removedSources = 0
                if sourceSetAuthority == .authoritative {
                    removedSources = try Self.countRows(
                        db,
                        sql: """
                            SELECT COUNT(*) FROM source_inventory
                            WHERE NOT EXISTS (
                              SELECT 1 FROM incoming_source i
                              WHERE i.source_key = source_inventory.source_key
                            );
                            """
                    )
                    removedItems += try Self.countRows(
                        db,
                        sql: """
                            SELECT COUNT(*) FROM source_item
                            WHERE NOT EXISTS (
                              SELECT 1 FROM incoming_source i
                              WHERE i.source_key = source_item.source_key
                            );
                            """
                    )
                    guard
                        sqlite3_exec(
                            db,
                            """
                            DELETE FROM source_inventory
                            WHERE NOT EXISTS (
                              SELECT 1 FROM incoming_source i
                              WHERE i.source_key = source_inventory.source_key
                            );
                            """,
                            nil,
                            nil,
                            nil
                        ) == SQLITE_OK
                    else {
                        throw LibrarySourceInventoryStoreError.corruptData
                    }
                }

                guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                    throw LibrarySourceInventoryStoreError.openFailed
                }
                self.lastCommittedWriteSequence = lease.sequence
                self.lastCommittedSnapshotSignature = persistenceSignature
                let result = LibrarySourceInventorySaveResult(
                    changedSources: changedSources,
                    changedItems: changedItems,
                    removedSources: removedSources,
                    removedItems: removedItems
                )
                if result.changedRows >= self.policy.walCheckpointRowThreshold {
                    _ = sqlite3_wal_checkpoint_v2(
                        db,
                        nil,
                        SQLITE_CHECKPOINT_TRUNCATE,
                        nil,
                        nil
                    )
                }
                return result
            } catch {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
    }

    /// Persists one confirmed access loss as an ordered O(1) fence before a later complete snapshot.
    /// This is the crash-recovery journal for a remote removal, not a schema migration.
    package func recordAccessLoss(
        for source: LibrarySource,
        using lease: WriteLease
    ) async throws {
        try await perform {
            try self.validate(lease)
            let tombstone = LibrarySourceInventory(
                source: source,
                accessState: .accessLost,
                authority: .authoritative,
                items: [],
                validationToken: nil
            )
            try LibrarySourceInventoryValidator.validate([tombstone])
            guard let db = self.db else {
                throw LibrarySourceInventoryStoreError.openFailed
            }
            let statements = try LibrarySourceInventorySaveStatements(db: db)
            let row = try self.prepare(
                Self.canonicalInventory(tombstone),
                statements: statements
            )
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
                throw LibrarySourceInventoryStoreError.openFailed
            }
            do {
                if let changedPayload = row.changedPayload {
                    try Self.executeBlobStatement(
                        statements.upsertSource,
                        bindings: [row.sourceKey, row.digest, changedPayload],
                        transient: self.transient
                    )
                }
                var deleteItems: OpaquePointer?
                guard
                    sqlite3_prepare_v2(
                        db,
                        "DELETE FROM source_item WHERE source_key=?;",
                        -1,
                        &deleteItems,
                        nil
                    ) == SQLITE_OK
                else {
                    throw LibrarySourceInventoryStoreError.corruptData
                }
                defer { sqlite3_finalize(deleteItems) }
                try Self.executeBlobStatement(
                    deleteItems,
                    bindings: [row.sourceKey],
                    transient: self.transient
                )
                guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                    throw LibrarySourceInventoryStoreError.openFailed
                }
                self.lastCommittedWriteSequence = lease.sequence
                self.lastCommittedSnapshotSignature = nil
            } catch {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
    }

    /// Closes the SQLite owner before deleting the database, WAL, and SHM as one unit.
    public func purge(using session: SessionLease) async throws -> SessionLease {
        try await perform {
            try self.validate(session)
            self.closeDatabase()
            guard Self.destroyDatabaseFiles(at: self.fileURL) else {
                throw LibrarySourceInventoryStoreError.openFailed
            }
            guard self.openVerified() else {
                throw LibrarySourceInventoryStoreError.openFailed
            }
            self.sessionGeneration &+= 1
            self.nextWriteSequence = 0
            self.lastCommittedWriteSequence = nil
            self.lastCommittedSnapshotSignature = nil
            return SessionLease(epoch: session.epoch, generation: self.sessionGeneration)
        }
    }

    /// Ends ownership before account teardown can remove the surrounding directory.
    public func close() async {
        await performWithoutThrowing {
            self.sessionGeneration &+= 1
            self.activeEpoch = nil
            self.nextWriteSequence = 0
            self.lastCommittedWriteSequence = nil
            self.lastCommittedSnapshotSignature = nil
            self.closeDatabase()
            if self.ownsFile {
                LibrarySourceInventoryOwnerRegistry.shared.release(
                    self.fileURL,
                    ownerID: self.ownerID
                )
                self.ownsFile = false
            }
        }
    }

    private func openVerified() -> Bool {
        if db != nil { return true }
        switch openOnce() {
        case .opened:
            return true
        case .failed:
            return false
        case .incompatible:
            guard Self.destroyDatabaseFiles(at: fileURL) else { return false }
            if case .opened = openOnce() { return true }
            return false
        }
    }

    private func openOnce() -> OpenResult {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return .failed
        }

        let compatibility = SQLiteStoreSchemaGate.compatibility(
            at: fileURL,
            schemaSQL: Self.persistentSchema,
            busyTimeoutMs: policy.busyTimeoutMs,
            versionIsCurrent: { Self.userVersion($0) == Self.schemaVersion }
        )
        switch compatibility {
        case .incompatible:
            return .incompatible
        case .unavailable, .retryLater:
            // The store stays as it is: it holds user data, so it is never replaced here.
            return .failed
        case .empty, .current:
            break
        }

        var handle: OpaquePointer?
        guard
            sqlite3_open_v2(
                fileURL.path,
                &handle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX,
                nil
            ) == SQLITE_OK, let handle
        else {
            sqlite3_close(handle)
            return .failed
        }
        func close(_ result: OpenResult) -> OpenResult {
            sqlite3_close(handle)
            return result
        }

        guard sqlite3_busy_timeout(handle, Int32(clamping: policy.busyTimeoutMs)) == SQLITE_OK,
            sqlite3_exec(handle, "PRAGMA foreign_keys=ON;", nil, nil, nil) == SQLITE_OK
        else { return close(.failed) }

        if compatibility == .empty {
            // A file with no application objects but a nonzero marker is still incompatible. Check
            // this before WAL or any other persistent pragma can modify the file.
            guard Self.userVersion(handle) == 0,
                SQLiteStoreSchemaGate.state(of: handle) == .empty
            else { return close(.incompatible) }
            guard
                SQLiteStoreSchemaGate.initializeCurrentSchema(
                    handle,
                    schemaSQL: Self.persistentSchema,
                    stamp: {
                        sqlite3_exec(
                            handle,
                            "PRAGMA user_version=\(Self.schemaVersion);",
                            nil,
                            nil,
                            nil
                        ) == SQLITE_OK
                    }
                )
            else {
                let code = sqlite3_errcode(handle)
                return close(
                    code == SQLITE_OK || Self.isConfirmedCorruption(code) ? .incompatible : .failed
                )
            }
        }

        SQLiteStoreSchemaGate.configureConnection(handle, policy: policy)
        guard Self.userVersion(handle) == Self.schemaVersion,
            SQLiteStoreSchemaGate.matchesCurrentSchema(handle, schemaSQL: Self.persistentSchema)
        else {
            let code = sqlite3_errcode(handle)
            return close(
                code == SQLITE_OK || Self.isConfirmedCorruption(code) ? .incompatible : .failed
            )
        }
        guard sqlite3_exec(handle, Self.temporarySchema, nil, nil, nil) == SQLITE_OK else {
            return close(.failed)
        }
        db = handle
        return .opened
    }

    private static let persistentSchema = """
        CREATE TABLE source_inventory(
          source_key BLOB NOT NULL PRIMARY KEY,
          payload_digest BLOB NOT NULL,
          payload BLOB NOT NULL
        ) WITHOUT ROWID;
        CREATE TABLE source_item(
          source_key BLOB NOT NULL,
          item_key BLOB NOT NULL,
          payload_digest BLOB NOT NULL,
          payload BLOB NOT NULL,
          PRIMARY KEY(source_key, item_key),
          FOREIGN KEY(source_key) REFERENCES source_inventory(source_key) ON DELETE CASCADE
        ) WITHOUT ROWID;
        """

    private static let temporarySchema = """
        CREATE TEMP TABLE incoming_source(
          source_key BLOB NOT NULL PRIMARY KEY
        ) WITHOUT ROWID;
        CREATE TEMP TABLE incoming_authoritative_source(
          source_key BLOB NOT NULL PRIMARY KEY
        ) WITHOUT ROWID;
        CREATE TEMP TABLE incoming_item(
          source_key BLOB NOT NULL,
          item_key BLOB NOT NULL,
          PRIMARY KEY(source_key, item_key)
        ) WITHOUT ROWID;
        """

    private static func userVersion(_ db: OpaquePointer?) -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK else {
            return -1
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1
    }

    private static func countRows(_ db: OpaquePointer?, sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw readError(sqlite3_errcode(db))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw readError(sqlite3_errcode(db))
        }
        let count = Int(sqlite3_column_int64(statement, 0))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw readError(sqlite3_errcode(db))
        }
        return count
    }

    private static func isConfirmedCorruption(_ code: Int32) -> Bool {
        let primary = code & 0xFF
        return primary == SQLITE_CORRUPT
            || primary == SQLITE_NOTADB
            || primary == SQLITE_FORMAT
            || primary == SQLITE_SCHEMA
    }

    private static func readError(_ code: Int32) -> LibrarySourceInventoryStoreError {
        isConfirmedCorruption(code) ? .corruptData : .openFailed
    }

    private func resetCorruptStoreLocked() throws {
        closeDatabase()
        guard Self.destroyDatabaseFiles(at: fileURL), case .opened = openOnce() else {
            throw LibrarySourceInventoryStoreError.openFailed
        }
    }

    private func closeDatabase() {
        guard let db else { return }
        sqlite3_exec(db, "PRAGMA optimize;", nil, nil, nil)
        sqlite3_close(db)
        self.db = nil
    }

    private static func destroyDatabaseFiles(at url: URL) -> Bool {
        url.lastPathComponent == databaseFileName && SQLiteStoreSchemaGate.removeDatabaseFiles(at: url)
    }

    private func prepare(
        _ inventory: LibrarySourceInventory,
        statements: LibrarySourceInventorySaveStatements
    ) throws -> PreparedSourceRow {
        let sourceKey = sourceKey(for: inventory.source.id)
        let sourcePlaintext = try encode(StoredSource(inventory: inventory))
        let sourceDigest = payloadDigest(sourcePlaintext)
        let existingSourceDigest = try Self.readDigest(
            statements.selectSourceDigest,
            bindings: [sourceKey],
            transient: transient
        )
        let sourcePayload: Data? =
            try existingSourceDigest == sourceDigest
            ? nil : seal(sourcePlaintext, domain: "source", rowKey: sourceKey)
        let items = try inventory.items.map { item -> PreparedItemRow in
            let itemKey = itemKey(for: item.uid)
            let plaintext = try encode(item)
            let digest = payloadDigest(plaintext)
            let existingDigest = try Self.readDigest(
                statements.selectItemDigest,
                bindings: [sourceKey, itemKey],
                transient: transient
            )
            return PreparedItemRow(
                itemKey: itemKey,
                digest: digest,
                changedPayload: try existingDigest == digest
                    ? nil : seal(plaintext, domain: "item", rowKey: sourceKey + itemKey)
            )
        }
        return PreparedSourceRow(
            sourceKey: sourceKey,
            digest: sourceDigest,
            changedPayload: sourcePayload,
            isAuthoritative: inventory.authority == .authoritative,
            items: items
        )
    }

    private static func readDigest(
        _ statement: OpaquePointer?,
        bindings: [Data],
        transient: sqlite3_destructor_type
    ) throws -> Data? {
        guard sqlite3_reset(statement) == SQLITE_OK,
            sqlite3_clear_bindings(statement) == SQLITE_OK
        else { throw LibrarySourceInventoryStoreError.corruptData }
        for (offset, binding) in bindings.enumerated() {
            guard
                bind(
                    binding,
                    to: statement,
                    at: Int32(offset + 1),
                    transient: transient
                )
            else { throw LibrarySourceInventoryStoreError.corruptData }
        }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let digest = columnData(statement, 0) else {
                throw LibrarySourceInventoryStoreError.corruptData
            }
            return digest
        case SQLITE_DONE:
            return nil
        case let result:
            throw readError(result)
        }
    }

    private static func executeBlobStatement(
        _ statement: OpaquePointer?,
        bindings: [Data],
        transient: sqlite3_destructor_type
    ) throws {
        guard sqlite3_reset(statement) == SQLITE_OK,
            sqlite3_clear_bindings(statement) == SQLITE_OK
        else { throw LibrarySourceInventoryStoreError.corruptData }
        for (offset, binding) in bindings.enumerated() {
            guard
                bind(
                    binding,
                    to: statement,
                    at: Int32(offset + 1),
                    transient: transient
                )
            else { throw LibrarySourceInventoryStoreError.corruptData }
        }
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE else { throw readError(step) }
    }

    private func sourceKey(for sourceID: SourceID) -> Data {
        keyedDigest(Data(sourceID.rawValue.utf8), domain: "source-key")
    }

    private func itemKey(for uid: PhotoUID) -> Data {
        var data = Data()
        Self.appendLengthPrefixed(Data(uid.volumeID.utf8), to: &data)
        Self.appendLengthPrefixed(Data(uid.nodeID.utf8), to: &data)
        return keyedDigest(data, domain: "item-key")
    }

    private static func appendLengthPrefixed(_ value: Data, to data: inout Data) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }

    private func payloadDigest(_ plaintext: Data) -> Data {
        keyedDigest(plaintext, domain: "payload-digest")
    }

    private func keyedDigest(_ data: Data, domain: String) -> Data {
        var input = Data(Self.cipherNamespace.utf8)
        input.append(0)
        input.append(contentsOf: accountUID.utf8)
        input.append(0)
        input.append(contentsOf: domain.utf8)
        input.append(0)
        input.append(data)
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: indexKey))
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    private func seal(_ plaintext: Data, domain: String, rowKey: Data) throws -> Data {
        let box = try AES.GCM.seal(
            plaintext,
            using: encryptionKey,
            authenticating: additionalAuthenticatedData(domain: domain, rowKey: rowKey)
        )
        guard let combined = box.combined else {
            throw LibrarySourceInventoryStoreError.corruptData
        }
        return combined
    }

    private func open<T: Decodable>(
        _ payload: Data,
        domain: String,
        rowKey: Data
    ) throws -> T {
        do {
            let box = try AES.GCM.SealedBox(combined: payload)
            let plaintext = try AES.GCM.open(
                box,
                using: encryptionKey,
                authenticating: additionalAuthenticatedData(domain: domain, rowKey: rowKey)
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(T.self, from: plaintext)
        } catch {
            throw LibrarySourceInventoryStoreError.corruptData
        }
    }

    private func additionalAuthenticatedData(domain: String, rowKey: Data) -> Data {
        var data = Data(Self.cipherNamespace.utf8)
        data.append(0)
        data.append(contentsOf: accountUID.utf8)
        data.append(0)
        data.append(contentsOf: domain.utf8)
        data.append(0)
        data.append(rowKey)
        return data
    }

    private func perform<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }

    private func performWithoutThrowing<T: Sendable>(
        _ operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: operation())
            }
        }
    }

    private func validate(_ session: SessionLease) throws {
        guard activeEpoch == session.epoch,
            sessionGeneration == session.generation
        else { throw LibrarySourceInventoryStoreError.staleSession }
    }

    private func validate(_ lease: WriteLease) throws {
        guard activeEpoch == lease.epoch,
            sessionGeneration == lease.sessionGeneration
        else { throw LibrarySourceInventoryStoreError.staleSession }
        guard lease.sequence <= nextWriteSequence,
            lastCommittedWriteSequence.map({ lease.sequence > $0 }) ?? true
        else { throw LibrarySourceInventoryStoreError.staleWriteLease }
    }

    private static func canonicalInventory(
        _ inventory: LibrarySourceInventory
    ) -> LibrarySourceInventory {
        let orderedItems = inventory.items.sorted { lhs, rhs in
            let lhsHasTime = lhs.knownFields.contains(.captureTime)
            let rhsHasTime = rhs.knownFields.contains(.captureTime)
            if lhsHasTime != rhsHasTime { return lhsHasTime }
            if lhsHasTime {
                let lhsTime = lhs.item.captureTime.timeIntervalSince1970
                let rhsTime = rhs.item.captureTime.timeIntervalSince1970
                if lhsTime != rhsTime { return lhsTime < rhsTime }
            }
            if lhs.uid.volumeID != rhs.uid.volumeID {
                return lhs.uid.volumeID.utf8.lexicographicallyPrecedes(rhs.uid.volumeID.utf8)
            }
            return lhs.uid.nodeID.utf8.lexicographicallyPrecedes(rhs.uid.nodeID.utf8)
        }
        return LibrarySourceInventory(
            source: inventory.source,
            accessState: inventory.accessState,
            authority: inventory.authority,
            items: orderedItems,
            validationToken: inventory.validationToken
        )
    }

    private static func bind(
        _ data: Data,
        to statement: OpaquePointer?,
        at index: Int32,
        transient: sqlite3_destructor_type
    ) -> Bool {
        data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
                == SQLITE_OK
        }
    }

    private static func columnData(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count >= 0 else { return nil }
        if count == 0 { return Data() }
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: count)
    }
}

private final class LibrarySourceInventorySaveStatements {
    let incomingSource: OpaquePointer?
    let incomingAuthoritativeSource: OpaquePointer?
    let incomingItem: OpaquePointer?
    let selectSourceDigest: OpaquePointer?
    let selectItemDigest: OpaquePointer?
    let upsertSource: OpaquePointer?
    let upsertItem: OpaquePointer?

    init(db: OpaquePointer?) throws {
        var prepared: [OpaquePointer?] = []
        func prepare(_ sql: String) throws -> OpaquePointer? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw LibrarySourceInventoryStoreError.corruptData
            }
            prepared.append(statement)
            return statement
        }
        do {
            incomingSource = try prepare(
                "INSERT INTO incoming_source(source_key) VALUES(?);"
            )
            incomingAuthoritativeSource = try prepare(
                "INSERT INTO incoming_authoritative_source(source_key) VALUES(?);"
            )
            incomingItem = try prepare(
                "INSERT INTO incoming_item(source_key, item_key) VALUES(?, ?);"
            )
            selectSourceDigest = try prepare(
                "SELECT payload_digest FROM source_inventory WHERE source_key=?;"
            )
            selectItemDigest = try prepare(
                "SELECT payload_digest FROM source_item WHERE source_key=? AND item_key=?;"
            )
            upsertSource = try prepare(
                """
                INSERT INTO source_inventory(source_key, payload_digest, payload)
                VALUES(?, ?, ?)
                ON CONFLICT(source_key) DO UPDATE SET
                  payload_digest=excluded.payload_digest,
                  payload=excluded.payload;
                """
            )
            upsertItem = try prepare(
                """
                INSERT INTO source_item(source_key, item_key, payload_digest, payload)
                VALUES(?, ?, ?, ?)
                ON CONFLICT(source_key, item_key) DO UPDATE SET
                  payload_digest=excluded.payload_digest,
                  payload=excluded.payload;
                """
            )
            prepared.removeAll(keepingCapacity: false)
        } catch {
            prepared.forEach { sqlite3_finalize($0) }
            throw error
        }
    }

    deinit {
        sqlite3_finalize(incomingSource)
        sqlite3_finalize(incomingAuthoritativeSource)
        sqlite3_finalize(incomingItem)
        sqlite3_finalize(selectSourceDigest)
        sqlite3_finalize(selectItemDigest)
        sqlite3_finalize(upsertSource)
        sqlite3_finalize(upsertItem)
    }
}

private final class LibrarySourceInventoryOwnerRegistry: @unchecked Sendable {
    static let shared = LibrarySourceInventoryOwnerRegistry()

    private let lock = NSLock()
    private var owners: [String: UUID] = [:]

    func acquire(_ fileURL: URL, ownerID: UUID) -> Bool {
        lock.withLock {
            let key = fileURL.standardizedFileURL.path
            guard owners[key] == nil || owners[key] == ownerID else { return false }
            owners[key] = ownerID
            return true
        }
    }

    func release(_ fileURL: URL, ownerID: UUID) {
        lock.withLock {
            let key = fileURL.standardizedFileURL.path
            guard owners[key] == ownerID else { return }
            owners.removeValue(forKey: key)
        }
    }
}
