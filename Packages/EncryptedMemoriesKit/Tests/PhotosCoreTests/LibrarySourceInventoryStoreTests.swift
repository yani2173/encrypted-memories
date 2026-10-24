import CryptoKit
import Foundation
import SQLite3
import XCTest

@testable import PhotosCore

final class LibrarySourceInventoryStoreTests: XCTestCase {
    private let encryptionKey = SymmetricKey(data: Data(repeating: 0xA5, count: 32))

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "EncryptedMemories-LibrarySourceInventoryStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func source(_ id: String, included: Bool = true) -> LibrarySource {
        LibrarySource(
            id: SourceID(id),
            capabilities: [.readMetadata, .readThumbnail, .readContent],
            precedence: 1,
            isIncluded: included
        )
    }

    private func item(_ id: String) -> LibrarySourceItem {
        LibrarySourceItem(
            item: PhotoItem(
                uid: PhotoUID(volumeID: "volume", nodeID: id),
                captureTime: Date(timeIntervalSince1970: 42),
                mediaType: "image/heic",
                tags: [.favorites]
            ),
            knownFields: [.captureTime, .mediaType]
        )
    }

    private func activate(
        _ store: LibrarySourceInventoryStore
    ) async throws -> LibrarySourceInventoryStore.SessionLease {
        try await store.activate(for: LibrarySourceGraph().runtimeEpoch)
    }

    private func makeStore(
        _ directory: URL,
        key: SymmetricKey? = nil
    ) -> LibrarySourceInventoryStore {
        LibrarySourceInventoryStore(
            directory: directory,
            accountUID: "test-account",
            encryptionKey: key ?? encryptionKey
        )
    }

    private func save(
        _ inventories: [LibrarySourceInventory],
        to store: LibrarySourceInventoryStore,
        session: LibrarySourceInventoryStore.SessionLease
    ) async throws {
        let lease = try await store.captureWriteLease(using: session)
        _ = try await store.save(
            inventories,
            sourceSetAuthority: .authoritative,
            using: lease
        )
    }

    func testRoundTripPreservesPartialMetadataAndTombstonesWithoutRestoringAuthority() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        let session = try await activate(store)
        let cached = LibrarySourceInventory(
            source: source("cached", included: false),
            accessState: .available,
            authority: .authoritative,
            items: [item("cached-item")],
            validationToken: "revision"
        )
        let tombstone = LibrarySourceInventory(
            source: source("removed"),
            accessState: .accessLost,
            authority: .authoritative,
            items: [],
            validationToken: nil
        )

        try await save([tombstone, cached], to: store, session: session)
        let restored = try await store.load(using: session)
        let graph = try LibrarySourceGraph(restoring: restored)

        XCTAssertEqual(restored.map(\.source.id), [SourceID("cached"), SourceID("removed")])
        XCTAssertFalse(restored[0].source.isIncluded, "rebuildable inventory must not persist projection choices")
        XCTAssertEqual(restored[0].items[0].knownFields, [.captureTime, .mediaType])
        XCTAssertEqual(restored[0].items[0].item.tags, [])
        XCTAssertEqual(graph.inventory(for: SourceID("cached"))?.authority, .cached)
        XCTAssertEqual(graph.inventory(for: SourceID("cached"))?.accessState, .temporarilyUnavailable)
        XCTAssertEqual(graph.inventory(for: SourceID("removed"))?.accessState, .accessLost)
        XCTAssertFalse(graph.retentionDerivedDataScope().isAuthoritative)
    }

    func testOrderedAccessLossFenceSurvivesRestartWithoutACompleteSnapshotSave() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let removedSource = source("removed")
        do {
            let store = makeStore(directory)
            let session = try await activate(store)
            try await save(
                [
                    LibrarySourceInventory(
                        source: removedSource,
                        accessState: .available,
                        authority: .authoritative,
                        items: [item("remote-item")]
                    )
                ],
                to: store,
                session: session
            )
            let fenceLease = try await store.captureWriteLease(using: session)
            try await store.recordAccessLoss(for: removedSource, using: fenceLease)
            await store.close()
        }

        let reopened = makeStore(directory)
        let reopenedSession = try await activate(reopened)
        let restored = try await reopened.load(using: reopenedSession)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].source.id, removedSource.id)
        XCTAssertEqual(restored[0].accessState, .accessLost)
        XCTAssertEqual(restored[0].authority, .authoritative)
        XCTAssertTrue(restored[0].items.isEmpty)
        await reopened.close()
    }

    func testDuplicateSourceSaveFailsWithoutReplacingExistingDocument() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        let session = try await activate(store)
        let original = LibrarySourceInventory(
            source: source("original"),
            accessState: .temporarilyUnavailable,
            authority: .cached,
            items: [item("original-item")]
        )
        try await save([original], to: store, session: session)
        let duplicate = LibrarySourceInventory(
            source: source("duplicate"),
            accessState: .temporarilyUnavailable,
            authority: .cached,
            items: []
        )

        do {
            try await save([duplicate, duplicate], to: store, session: session)
            XCTFail("duplicate source IDs must fail")
        } catch {
            XCTAssertEqual(
                error as? LibrarySourceInventoryValidationError,
                .duplicateSourceID(SourceID("duplicate"))
            )
        }
        let retained = try await store.load(using: session)
        XCTAssertEqual(retained.map(\.source.id), [SourceID("original")])
    }

    func testIncompatibleSchemaResetsWithoutMigration() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(LibrarySourceInventoryStore.databaseFileName)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                db,
                "CREATE TABLE legacy(value TEXT); PRAGMA user_version=99;",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(db)

        let store = makeStore(directory)
        let session = try await activate(store)
        let restored = try await store.load(using: session)

        XCTAssertEqual(restored.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testAFileThatAnotherConnectionHoldsIsNeverReplaced() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(LibrarySourceInventoryStore.databaseFileName)
        var holder: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &holder), SQLITE_OK)
        defer { sqlite3_close(holder) }
        XCTAssertEqual(
            sqlite3_exec(
                holder, "CREATE TABLE legacy(value TEXT); INSERT INTO legacy VALUES ('kept'); PRAGMA user_version=99;",
                nil, nil, nil),
            SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(holder, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)

        let store = LibrarySourceInventoryStore(
            directory: directory, accountUID: "test-account", encryptionKey: encryptionKey,
            policy: LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 0))
        do {
            _ = try await activate(store)
            XCTFail("a file that another connection holds cannot be opened")
        } catch {}
        XCTAssertEqual(sqlite3_exec(holder, "COMMIT;", nil, nil, nil), SQLITE_OK)

        // The inventory holds user data: a lock says nothing about the schema, so the file keeps its content.
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(holder, "SELECT value FROM legacy;", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "kept")
    }

    func testInvalidInventoryCannotReplaceExistingDocument() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        let session = try await activate(store)
        let original = LibrarySourceInventory(
            source: source("original"),
            accessState: .temporarilyUnavailable,
            authority: .cached,
            items: [item("original-item")]
        )
        try await save([original], to: store, session: session)
        let duplicatedItem = item("duplicate-item")
        let invalid = LibrarySourceInventory(
            source: source("invalid"),
            accessState: .available,
            authority: .authoritative,
            items: [duplicatedItem, duplicatedItem]
        )

        do {
            try await save([invalid], to: store, session: session)
            XCTFail("duplicate item identities must fail")
        } catch {
            XCTAssertEqual(
                error as? LibrarySourceInventoryValidationError,
                .duplicateItemUID(sourceID: SourceID("invalid"), uid: duplicatedItem.uid)
            )
        }
        let retained = try await store.load(using: session)
        XCTAssertEqual(retained.map(\.source.id), [SourceID("original")])
    }

    func testInvalidTombstoneCannotBeRestoredAsEmptyAuthority() async throws {
        let invalid = LibrarySourceInventory(
            source: source("invalid-tombstone"),
            accessState: .accessLost,
            authority: .authoritative,
            items: [item("must-not-be-hidden")],
            validationToken: "stale"
        )

        XCTAssertThrowsError(try LibrarySourceGraph(restoring: [invalid])) { error in
            XCTAssertEqual(
                error as? LibrarySourceInventoryValidationError,
                .invalidState(SourceID("invalid-tombstone"))
            )
        }
    }

    func testPurgeRemovesOnlyTheInventoryDocument() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        let session = try await activate(store)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unrelated = directory.appendingPathComponent("unrelated")
        try Data("keep".utf8).write(to: unrelated)
        try await save([], to: store, session: session)

        let renewedSession = try await store.purge(using: session)

        let restored = try await store.load(using: renewedSession)
        XCTAssertEqual(restored.count, 0)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
    }

    func testPurgeRejectsAWriteCapturedBeforeTheBarrier() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        let session = try await activate(store)
        let staleWrite = try await store.captureWriteLease(using: session)

        let renewedSession = try await store.purge(using: session)

        do {
            try await store.save([], sourceSetAuthority: .authoritative, using: staleWrite)
            XCTFail("a pre-purge write must not recreate the document")
        } catch {
            XCTAssertEqual(error as? LibrarySourceInventoryStoreError, .staleSession)
        }
        let restored = try await store.load(using: renewedSession)
        XCTAssertEqual(restored.count, 0)
    }

    func testNewerWriteLeaseRejectsDelayedOlderSnapshot() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        let session = try await activate(store)
        let oldInventory = LibrarySourceInventory(
            source: source("old"),
            accessState: .temporarilyUnavailable,
            authority: .cached,
            items: [item("old-item")]
        )
        let newInventory = LibrarySourceInventory(
            source: source("new"),
            accessState: .temporarilyUnavailable,
            authority: .cached,
            items: [item("new-item")]
        )
        let oldWrite = try await store.captureWriteLease(using: session)
        let newWrite = try await store.captureWriteLease(using: session)

        try await store.save(
            [newInventory],
            sourceSetAuthority: .authoritative,
            using: newWrite
        )
        do {
            try await store.save(
                [oldInventory],
                sourceSetAuthority: .authoritative,
                using: oldWrite
            )
            XCTFail("an older write must not replace the newest snapshot")
        } catch {
            XCTAssertEqual(error as? LibrarySourceInventoryStoreError, .staleWriteLease)
        }
        let restored = try await store.load(using: session)
        XCTAssertEqual(restored.map(\.source.id), [SourceID("new")])
    }

    func testAbandonedNewerLeaseDoesNotStrandAnOlderValidSave() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        let session = try await activate(store)
        let oldWrite = try await store.captureWriteLease(using: session)
        _ = try await store.captureWriteLease(using: session)
        let inventory = LibrarySourceInventory(
            source: source("committed"),
            accessState: .temporarilyUnavailable,
            authority: .cached,
            items: [item("asset")]
        )

        _ = try await store.save(
            [inventory],
            sourceSetAuthority: .authoritative,
            using: oldWrite
        )
        let restoredSourceIDs = try await store.load(using: session).map(\.source.id)

        XCTAssertEqual(
            restoredSourceIDs,
            [SourceID("committed")]
        )
    }

    func testEquivalentInventoriesWriteNoPersistentRowsAndStayEncrypted() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        let session = try await activate(store)
        func completeItem(_ id: String, time: TimeInterval) -> LibrarySourceItem {
            .complete(
                PhotoItem(
                    uid: PhotoUID(volumeID: "volume", nodeID: id),
                    captureTime: Date(timeIntervalSince1970: time),
                    mediaType: "image/heic",
                    tags: [.bursts, .favorites, .videos]
                )
            )
        }
        let first = LibrarySourceInventory(
            source: source("first"),
            accessState: .available,
            authority: .authoritative,
            items: [completeItem("later", time: 2), completeItem("earlier", time: 1)]
        )
        let second = LibrarySourceInventory(
            source: source("second"),
            accessState: .temporarilyUnavailable,
            authority: .cached,
            items: [completeItem("second", time: 3)]
        )
        let firstLease = try await store.captureWriteLease(using: session)
        let firstResult = try await store.save(
            [second, first],
            sourceSetAuthority: .authoritative,
            using: firstLease
        )
        let secondLease = try await store.captureWriteLease(using: session)
        let secondResult = try await store.save(
            [
                LibrarySourceInventory(
                    source: first.source,
                    accessState: first.accessState,
                    authority: first.authority,
                    items: Array(first.items.reversed()),
                    validationToken: first.validationToken
                ),
                second,
            ],
            sourceSetAuthority: .authoritative,
            using: secondLease
        )

        XCTAssertGreaterThan(firstResult.changedRows, 0)
        XCTAssertEqual(secondResult.changedRows, 0)
        var persisted = Data()
        for name in LibrarySourceInventoryStore.databaseFileNames() {
            let url = directory.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url) {
                persisted.append(data)
            }
        }
        XCTAssertNil(persisted.range(of: Data("first".utf8)))
        XCTAssertNil(persisted.range(of: Data("earlier".utf8)))
    }

    func testCachedSnapshotCannotDeletePreviouslyAuthoritativeItemsOrSources() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        let session = try await activate(store)
        let retainedSource = source("retained")
        let otherSource = source("other")
        try await save(
            [
                LibrarySourceInventory(
                    source: retainedSource,
                    accessState: .available,
                    authority: .authoritative,
                    items: [item("a"), item("b")]
                ),
                LibrarySourceInventory(
                    source: otherSource,
                    accessState: .available,
                    authority: .authoritative,
                    items: [item("other")]
                ),
            ],
            to: store,
            session: session
        )
        let lease = try await store.captureWriteLease(using: session)
        _ = try await store.save(
            [
                LibrarySourceInventory(
                    source: retainedSource,
                    accessState: .temporarilyUnavailable,
                    authority: .cached,
                    items: [item("a")]
                )
            ],
            sourceSetAuthority: .hydrating,
            using: lease
        )

        let restored = try await store.load(using: session)
        XCTAssertEqual(restored.map(\.source.id), [SourceID("other"), SourceID("retained")])
        XCTAssertEqual(
            Set(restored.first { $0.source.id == retainedSource.id }?.items.map(\.uid.nodeID) ?? []),
            ["a", "b"]
        )
    }

    func testAuthoritativeSnapshotRemovesAbsentItemsAndSources() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        let session = try await activate(store)
        let retainedSource = source("retained")
        try await save(
            [
                LibrarySourceInventory(
                    source: retainedSource,
                    accessState: .available,
                    authority: .authoritative,
                    items: [item("a"), item("b")]
                ),
                LibrarySourceInventory(
                    source: source("removed"),
                    accessState: .available,
                    authority: .authoritative,
                    items: [item("removed")]
                ),
            ],
            to: store,
            session: session
        )
        let lease = try await store.captureWriteLease(using: session)
        _ = try await store.save(
            [
                LibrarySourceInventory(
                    source: retainedSource,
                    accessState: .available,
                    authority: .authoritative,
                    items: [item("a")]
                )
            ],
            sourceSetAuthority: .authoritative,
            using: lease
        )

        let restored = try await store.load(using: session)
        XCTAssertEqual(restored.map(\.source.id), [retainedSource.id])
        XCTAssertEqual(restored[0].items.map(\.uid.nodeID), ["a"])
    }

    func testMalformedCurrentSchemaResetsInsteadOfRepairingInPlace() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(LibrarySourceInventoryStore.databaseFileName)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                db,
                "CREATE TABLE source_inventory(source_key BLOB); PRAGMA user_version=1;",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(db)

        let store = makeStore(directory)
        let session = try await activate(store)
        let restored = try await store.load(using: session)
        XCTAssertTrue(restored.isEmpty)
    }

    func testAuthenticatedPayloadCorruptionResetsTheDerivedStore() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        let session = try await activate(store)
        try await save(
            [
                LibrarySourceInventory(
                    source: source("corrupt"),
                    accessState: .available,
                    authority: .authoritative,
                    items: [item("asset")]
                )
            ],
            to: store,
            session: session
        )
        await store.close()

        let file = directory.appendingPathComponent(LibrarySourceInventoryStore.databaseFileName)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(db, "UPDATE source_inventory SET payload=x'00';", nil, nil, nil),
            SQLITE_OK
        )
        sqlite3_close(db)

        let reopened = makeStore(directory)
        let reopenedSession = try await activate(reopened)
        let restored = try await reopened.load(using: reopenedSession)
        XCTAssertTrue(restored.isEmpty)
    }

    func testOnlyOneStoreInstanceCanOwnADatabase() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = makeStore(directory)
        _ = try await activate(first)
        let second = makeStore(directory)

        do {
            _ = try await activate(second)
            XCTFail("a second writer must not acquire the same database")
        } catch {
            XCTAssertEqual(error as? LibrarySourceInventoryStoreError, .alreadyOwned)
        }

        await first.close()
        _ = try await activate(second)
    }

    func testLengthPrefixedItemKeysDoNotCollideOnEmbeddedNUL() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        let session = try await activate(store)
        let first = LibrarySourceItem(
            item: PhotoItem(
                uid: PhotoUID(volumeID: "a", nodeID: "b\0c"),
                captureTime: Date(timeIntervalSince1970: 1),
                mediaType: "image/jpeg"
            ),
            knownFields: [.captureTime, .mediaType]
        )
        let second = LibrarySourceItem(
            item: PhotoItem(
                uid: PhotoUID(volumeID: "a\0b", nodeID: "c"),
                captureTime: Date(timeIntervalSince1970: 2),
                mediaType: "image/jpeg"
            ),
            knownFields: [.captureTime, .mediaType]
        )
        try await save(
            [
                LibrarySourceInventory(
                    source: source("nul-safe"),
                    accessState: .available,
                    authority: .authoritative,
                    items: [first, second]
                )
            ],
            to: store,
            session: session
        )

        let restored = try await store.load(using: session)
        XCTAssertEqual(restored[0].items.count, 2)
    }

    func testSQLiteSchemaContainsNoPlaintextMediaMetadataColumns() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory)
        _ = try await activate(store)
        await store.close()
        let file = directory.appendingPathComponent(LibrarySourceInventoryStore.databaseFileName)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA table_info(source_item);", -1, &statement, nil), SQLITE_OK)
        var columns: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            columns.append(String(cString: sqlite3_column_text(statement, 1)))
        }
        sqlite3_finalize(statement)
        sqlite3_close(db)

        XCTAssertEqual(columns, ["source_key", "item_key", "payload_digest", "payload"])
    }
}
