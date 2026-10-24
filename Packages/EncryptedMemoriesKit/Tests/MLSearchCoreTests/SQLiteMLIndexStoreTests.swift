import Foundation
import PhotosCore
import SQLite3
import Testing

@testable import MLSearchCore

struct TestMLVectorCipher: MLVectorCipher {
    private let mask: UInt8 = 0xA5

    func seal(_ plaintext: Data, context: MLVectorCipherContext) throws -> Data {
        Data(plaintext.map { $0 ^ mask })
    }

    func open(_ ciphertext: Data, context: MLVectorCipherContext) throws -> Data {
        Data(ciphertext.map { $0 ^ mask })
    }

    /// A length-preserving scheme keeps sealed and plaintext sizes equal, which enables the store's
    /// pre-decryption byte-count validation.
    func sealedByteCount(forPlaintextByteCount plaintextByteCount: Int) -> Int? {
        plaintextByteCount
    }
}

/// Tests SQLite persistence, epoch isolation, and reopen behavior.
///
/// Each test uses a temporary database so it exercises real SQLite semantics without shared state.
@Suite struct SQLiteMLIndexStoreTests {
    private let descriptorV1 = MLModelDescriptor(identifier: "fixture-model", version: 1, embeddingDimension: 4)
    private let descriptorV2 = MLModelDescriptor(identifier: "fixture-model", version: 2, embeddingDimension: 4)

    private func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: "vol1", nodeID: id) }

    private func record(
        _ id: String, _ descriptor: MLModelDescriptor, _ vector: [Float32], captureTime: Date? = nil
    ) -> MLEmbeddingRecord {
        MLEmbeddingRecord(
            uid: uid(id),
            descriptor: descriptor,
            vector: ContiguousArray(vector),
            timestamp: Date(timeIntervalSince1970: 1_000),
            captureTime: captureTime
        )
    }

    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-index-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(SQLiteMLIndexStore.databaseFileName)
    }

    private func withStore(_ body: (SQLiteMLIndexStore, URL) throws -> Void) throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        try body(store, url)
        store.close()
    }

    @Test func currentMarkerWithWrongShapeResetsTheDerivedIndex() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        #expect(
            sqlite3_exec(
                handle,
                "CREATE TABLE legacy_vectors(value TEXT); PRAGMA user_version=5;",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        sqlite3_close(handle)

        let store = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        #expect(store.count(for: descriptorV1) == 0)
        store.close()

        handle = nil
        #expect(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        var statement: OpaquePointer?
        #expect(
            sqlite3_prepare_v2(
                handle,
                "SELECT COUNT(*) FROM sqlite_schema WHERE name='legacy_vectors';",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        )
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 0)
        sqlite3_finalize(statement)
        sqlite3_close(handle)
    }

    @Test func markerlessExactSchemaResetsInsteadOfAdoptingRows() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        first.upsert([record("cached", descriptorV1, [1, 0, 0, 0])])
        #expect(first.count(for: descriptorV1) == 1)
        first.close()

        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "PRAGMA user_version=0;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let rebuilt = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        #expect(rebuilt.count(for: descriptorV1) == 0)
        rebuilt.close()
    }

    @Test func roundTripsOneEmbedding() throws {
        try withStore { store, _ in
            let capture = Date(timeIntervalSince1970: 555)
            store.upsert([record("a0", descriptorV1, [0.1, 0.2, 0.3, 0.4], captureTime: capture)])

            let loaded = try #require(store.allRecords(for: descriptorV1).first)
            #expect(loaded.uid == uid("a0"))
            #expect(loaded.descriptor == descriptorV1)
            // Rows persist as binary16: the round trip returns the fp16-quantized values.
            let expected = ContiguousArray<Float32>([0.1, 0.2, 0.3, 0.4].map(MLFloat16Codec.quantized))
            #expect(loaded.vector == expected)
            for (stored, original) in zip(loaded.vector, [0.1, 0.2, 0.3, 0.4] as [Float32]) {
                #expect(abs(stored - original) <= abs(original) * 0.001)
            }
            #expect(loaded.timestamp == Date(timeIntervalSince1970: 1_000))
            #expect(loaded.captureTime == capture)
            let readResult1 = try store.contains(uid: uid("a0"), descriptor: descriptorV1)
            #expect(readResult1)
        }
    }

    @Test func batchUpsertStoresManyInOneTransaction() throws {
        try withStore { store, _ in
            let records = (0..<500).map { record("a\($0)", descriptorV1, [Float32($0), 0, 0, 0]) }
            let report = store.upsert(records)
            #expect(report.indexed == 500)
            #expect(report.skippedAlreadyIndexed == 0)
            #expect(store.count(for: descriptorV1) == 500)
        }
    }

    @Test func duplicateKeyIsFirstWriteWinsAndReported() throws {
        try withStore { store, _ in
            store.upsert([record("a0", descriptorV1, [1, 0, 0, 0])])
            let report = store.upsert([record("a0", descriptorV1, [0, 9, 9, 9])])
            #expect(report.indexed == 0)
            #expect(report.skippedAlreadyIndexed == 1)
            #expect(store.count(for: descriptorV1) == 1)
            // The stored vector is the first write, so the report and data agree.
            #expect(store.allRecords(for: descriptorV1).first?.vector == ContiguousArray<Float32>([1, 0, 0, 0]))
        }
    }

    @Test func dimensionMismatchRejectedAndCounted() throws {
        try withStore { store, _ in
            let report = store.upsert([
                record("a0", descriptorV1, [1, 0, 0, 0]),
                record("a1", descriptorV1, [1, 0]),
            ])
            #expect(report.indexed == 1)
            #expect(report.permanentFailure == 1)
            #expect(
                report.total == report.indexed + report.skippedAlreadyIndexed + report.permanentFailure
                    + report.transientFailure)
            let readResult2 = try store.contains(uid: uid("a1"), descriptor: descriptorV1) == false
            #expect(readResult2)
        }
    }

    @Test func indexedUIDsIsEpochScopedAndHandlesLargeInputs() throws {
        try withStore { store, _ in
            store.upsert((0..<450).map { record("a\($0)", descriptorV1, [Float32($0), 0, 0, 0]) })
            store.upsert([record("v2only", descriptorV2, [1, 0, 0, 0])])

            // 901 probe uids exercise multiple 200-pair chunks; v2-only and unknown uids must not match.
            var probes = (0..<450).map { uid("a\($0)") }
            probes.append(contentsOf: (0..<450).map { uid("missing\($0)") })
            probes.append(uid("v2only"))
            let members = try store.indexedUIDs(for: descriptorV1, from: probes)
            #expect(members.count == 450)
            #expect(!members.contains(uid("v2only")))
            #expect(!members.contains(uid("missing0")))
        }
    }

    @Test func closedStoreThrowsForPlanningMembershipReads() throws {
        let root = makeTempURL()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = try #require(SQLiteMLIndexStore(url: root, cipher: TestMLVectorCipher()))
        store.close()

        #expect(throws: MLIndexStoreReadError.storageUnavailable) {
            _ = try store.contains(uid: uid("missing"), descriptor: descriptorV1)
        }
        #expect(throws: MLIndexStoreReadError.storageUnavailable) {
            _ = try store.indexedUIDs(for: descriptorV1, from: [uid("missing")])
        }
        #expect(throws: MLIndexStoreReadError.storageUnavailable) {
            _ = try store.failureRecords(for: descriptorV1, from: [uid("missing")])
        }
        #expect(throws: MLIndexStoreReadError.storageUnavailable) {
            _ = try store.coverage(for: descriptorV1, allAssets: [uid("missing")])
        }
    }

    @Test func failedFailureRecordSQLReadDoesNotReturnAPartialSet() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        defer { store.close() }
        store.upsert([record("a0", descriptorV1, [1, 0, 0, 0])])

        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "DROP TABLE ml_failures;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        #expect(throws: MLIndexStoreReadError.storageUnavailable) {
            _ = try store.failureRecords(for: descriptorV1, from: [uid("a0"), uid("missing")])
        }
    }

    @Test func unknownPersistedFailureKindIsStorageUnavailable() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        defer { store.close() }

        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        #expect(
            sqlite3_exec(
                handle,
                """
                INSERT INTO ml_failures(
                  volume_id, node_id, model_identifier, model_version,
                  kind, reason, attempts, updated_at
                ) VALUES
                  ('vol1', 'permanent', 'fixture-model', 1, 'permanent', 'keep', 1, 1.0),
                  ('vol1', 'unknown', 'fixture-model', 1, 'future-kind', 'reject', 1, 2.0);
                """,
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        sqlite3_close(handle)

        do {
            _ = try store.failureRecords(
                for: descriptorV1,
                from: [uid("permanent"), uid("unknown")]
            )
            Issue.record("unknown persisted failure kinds must not be skipped")
        } catch let error as MLIndexStoreReadError {
            #expect(error == .storageUnavailable)
        } catch {
            Issue.record("unexpected failure-record read error: \(error)")
        }
    }

    @Test func modelVersionChangeCreatesSeparateEpoch() throws {
        try withStore { store, _ in
            store.upsert([record("a0", descriptorV1, [1, 0, 0, 0])])
            #expect(store.count(for: descriptorV2) == 0)
            let readResult3 = try store.contains(uid: uid("a0"), descriptor: descriptorV2) == false
            #expect(readResult3)

            store.upsert([record("a0", descriptorV2, [2, 0, 0, 0])])
            #expect(store.count(for: descriptorV1) == 1)
            #expect(store.count(for: descriptorV2) == 1)
            #expect(store.allRecords(for: descriptorV1).first?.vector.first == 1)
            #expect(store.allRecords(for: descriptorV2).first?.vector.first == 2)
        }
    }

    @Test func removeOneUID() throws {
        try withStore { store, _ in
            store.upsert([
                record("a0", descriptorV1, [1, 0, 0, 0]),
                record("a1", descriptorV1, [0, 1, 0, 0]),
            ])
            store.remove(uid: uid("a0"), descriptor: descriptorV1)
            let readResult4 = try store.contains(uid: uid("a0"), descriptor: descriptorV1) == false
            #expect(readResult4)
            let readResult5 = try store.contains(uid: uid("a1"), descriptor: descriptorV1)
            #expect(readResult5)
            #expect(store.count(for: descriptorV1) == 1)
        }
    }

    @Test func batchRemovalUsesOneGenerationAndClearsFailureState() throws {
        try withStore { store, _ in
            store.upsert([
                record("a0", descriptorV1, [1, 0, 0, 0]),
                record("a1", descriptorV1, [0, 1, 0, 0]),
                record("keep", descriptorV1, [0, 0, 1, 0]),
            ])
            let failed = uid("failed")
            #expect(
                store.recordFailures([
                    MLIndexFailureRecord(
                        uid: failed,
                        descriptor: descriptorV1,
                        kind: .permanent,
                        reason: "unsupported",
                        attempts: 1
                    )
                ]))
            #expect(Set(store.allTrackedUIDs(for: descriptorV1)) == [uid("a0"), uid("a1"), uid("keep"), failed])
            let generation = store.generation(for: descriptorV1)

            store.remove(uids: [uid("a0"), uid("a1"), failed], descriptor: descriptorV1)

            #expect(store.generation(for: descriptorV1) == generation + 1)
            #expect(store.allIndexedUIDs(for: descriptorV1) == [uid("keep")])
            let readResult6 = try store.failureRecords(for: descriptorV1, from: [failed]).isEmpty
            #expect(readResult6)
        }
    }

    @Test func authoritativeReconciliationUsesColdStoreStateThenExactInventoryDelta() throws {
        try withStore { store, _ in
            let original = (0..<450).map { uid("asset-\($0)") }
            store.upsert(
                original.map {
                    MLEmbeddingRecord(
                        uid: $0,
                        descriptor: descriptorV1,
                        vector: [1, 0, 0, 0],
                        timestamp: Date(timeIntervalSince1970: 1_000)
                    )
                }
            )
            let failed = uid("failed")
            #expect(
                store.recordFailures([
                    MLIndexFailureRecord(
                        uid: failed,
                        descriptor: descriptorV1,
                        kind: .permanent,
                        attempts: 1
                    )
                ]))

            let firstInventory = Array(original.prefix(225))
            let beforeColdReconciliation = store.generation(for: descriptorV1)
            #expect(
                store.reconcileTrackedUIDs(
                    currentAuthoritativeUIDs: firstInventory,
                    previousAuthoritativeUIDs: nil,
                    descriptor: descriptorV1
                ))
            #expect(Set(store.allIndexedUIDs(for: descriptorV1)) == Set(firstInventory))
            let readResult7 = try store.failureRecords(for: descriptorV1, from: [failed]).isEmpty
            #expect(readResult7)
            #expect(store.generation(for: descriptorV1) == beforeColdReconciliation + 1)

            let laterAsset = uid("later")
            store.upsert([
                MLEmbeddingRecord(
                    uid: laterAsset,
                    descriptor: descriptorV1,
                    vector: [0, 1, 0, 0],
                    timestamp: Date(timeIntervalSince1970: 2_000)
                )
            ])
            let previousInventory = firstInventory + [laterAsset]
            let nextInventory = Array(firstInventory.dropFirst(224))
            let beforeDeltaReconciliation = store.generation(for: descriptorV1)
            #expect(
                store.reconcileTrackedUIDs(
                    currentAuthoritativeUIDs: nextInventory,
                    previousAuthoritativeUIDs: previousInventory,
                    descriptor: descriptorV1
                ))
            #expect(store.allIndexedUIDs(for: descriptorV1) == nextInventory)
            #expect(store.generation(for: descriptorV1) == beforeDeltaReconciliation + 1)

            let beforeNoOp = store.generation(for: descriptorV1)
            #expect(
                store.reconcileTrackedUIDs(
                    currentAuthoritativeUIDs: nextInventory,
                    previousAuthoritativeUIDs: nextInventory,
                    descriptor: descriptorV1
                ))
            #expect(store.generation(for: descriptorV1) == beforeNoOp)
        }
    }

    @Test func reconciliationReportsFailureAfterStoreClosure() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        store.upsert([record("asset", descriptorV1, [1, 0, 0, 0])])
        store.close()

        #expect(
            !store.reconcileTrackedUIDs(
                currentAuthoritativeUIDs: [],
                previousAuthoritativeUIDs: [uid("asset")],
                descriptor: descriptorV1
            ))
    }

    @Test func removeAllForDescriptorLeavesOtherEpochsIntact() throws {
        try withStore { store, _ in
            store.upsert([record("a0", descriptorV1, [1, 0, 0, 0])])
            store.upsert([record("a0", descriptorV2, [1, 0, 0, 0])])
            #expect(store.removeAll(for: descriptorV1))
            #expect(store.count(for: descriptorV1) == 0)
            #expect(store.count(for: descriptorV2) == 1)
        }
    }

    @Test func removeAllReportsFailureAfterStoreClosure() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        store.upsert([record("asset", descriptorV1, [1, 0, 0, 0])])
        store.close()

        #expect(!store.removeAll(for: descriptorV1))
    }

    @Test func removeAllRollsBackEmbeddingsFailuresAndGenerationTogether() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        defer { store.close() }
        let embedded = uid("embedded")
        let failed = uid("failed")
        store.upsert([record("embedded", descriptorV1, [1, 0, 0, 0])])
        #expect(
            store.recordFailures([
                MLIndexFailureRecord(
                    uid: failed,
                    descriptor: descriptorV1,
                    kind: .permanent,
                    reason: "unsupported",
                    attempts: 1
                )
            ])
        )
        let generation = store.generation(for: descriptorV1)

        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        #expect(
            sqlite3_exec(
                handle,
                """
                CREATE TRIGGER reject_failure_cleanup
                BEFORE DELETE ON ml_failures
                BEGIN
                  SELECT RAISE(ABORT, 'injected cleanup failure');
                END;
                """,
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        sqlite3_close(handle)

        #expect(!store.removeAll(for: descriptorV1))
        let readResult8 = try store.contains(uid: embedded, descriptor: descriptorV1)
        #expect(readResult8)
        let readResult9 = try store.failureRecords(for: descriptorV1, from: [failed])[failed] != nil
        #expect(readResult9)
        #expect(store.generation(for: descriptorV1) == generation)

        handle = nil
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "DROP TRIGGER reject_failure_cleanup;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        #expect(store.removeAll(for: descriptorV1))
        #expect(store.allTrackedUIDs(for: descriptorV1).isEmpty)
        #expect(store.generation(for: descriptorV1) == generation + 1)
    }

    /// Another connection holds the file exclusively longer than the busy timeout. The derived index is never
    /// deleted for that, and it opens again with its records once the lock is gone.
    @Test func aFileThatAnotherConnectionHoldsIsKeptAndOpensAgainWithItsRecords() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        first.upsert([record("a0", descriptorV1, [1, 2, 3, 4])])
        first.close()
        var blocker: OpaquePointer?
        #expect(sqlite3_open(url.path, &blocker) == SQLITE_OK)
        #expect(sqlite3_exec(blocker, "PRAGMA locking_mode=EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(blocker, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)

        let noWait = LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 0)
        let busy = SQLiteMLIndexStore(url: url, policy: noWait, cipher: TestMLVectorCipher())
        busy?.close()
        #expect(sqlite3_exec(blocker, "COMMIT;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(blocker)

        #expect(busy == nil, "the store is unavailable while the lock lasts")
        #expect(FileManager.default.fileExists(atPath: url.path), "the index is not deleted")
        let reopened = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        defer { reopened.close() }
        #expect(reopened.count(for: descriptorV1) == 1)
    }

    @Test func reopenedStoreSeesPersistedRecords() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        first.upsert([
            record("a0", descriptorV1, [1, 2, 3, 4]),
            record("a1", descriptorV1, [5, 6, 7, 8]),
        ])
        first.close()

        let reopened = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        defer { reopened.close() }
        #expect(reopened.count(for: descriptorV1) == 2)
        #expect(try reopened.contains(uid: uid("a0"), descriptor: descriptorV1))
        #expect(reopened.allRecords(for: descriptorV1).map(\.uid.nodeID) == ["a0", "a1"])
        // Idempotent replay after restart: no duplicates.
        let replay = reopened.upsert([record("a0", descriptorV1, [1, 2, 3, 4])])
        #expect(replay.skippedAlreadyIndexed == 1)
        #expect(reopened.count(for: descriptorV1) == 2)
    }

    @Test func vectorBlockStreamsAllRowsInKeyOrder() throws {
        try withStore { store, _ in
            store.upsert([
                record("b1", descriptorV1, [0, 1, 0, 0]),
                record("a0", descriptorV1, [1, 0, 0, 0]),
            ])
            let block = store.vectorBlock(for: descriptorV1)
            #expect(block.count == 2)
            #expect(block.dimension == 4)
            #expect(block.uids.map(\.nodeID) == ["a0", "b1"])

            // The packed block must rank identically to the record path.
            let results = ReferenceDotProductScorer().rank(block: block, query: [1, 0, 0, 0], limit: 2)
            #expect(results.results.first?.uid == uid("a0"))
            #expect(results.results.first?.score == 1.0)
        }
    }

    @Test func vectorBlockPagesStayBoundedAndOrdered() throws {
        try withStore { store, _ in
            store.upsert(
                (0..<5).map {
                    record("a\($0)", descriptorV1, [Float32($0), 0, 0, 0])
                })
            var pages: [[String]] = []
            try store.forEachVectorBlock(for: descriptorV1, maximumRows: 2) { block in
                pages.append(block.uids.map(\.nodeID))
                #expect(block.count <= 2)
            }

            #expect(pages == [["a0", "a1"], ["a2", "a3"], ["a4"]])
        }
    }

    @Test(arguments: [1, 2, 3, 7])
    func vectorBlockPagesCrossVolumesWithoutMixingEpochs(maximumRows: Int) throws {
        try withStore { store, _ in
            let uids = ["a", "b", "c"].flatMap { volume in
                ["first", "last"].map { PhotoUID(volumeID: volume, nodeID: $0) }
            }
            for descriptor in [descriptorV1, descriptorV2] {
                store.upsert(
                    uids.reversed().map {
                        MLEmbeddingRecord(
                            uid: $0, descriptor: descriptor, vector: [Float32(descriptor.version), 0, 0, 0])
                    })
            }
            var streamed: [PhotoUID] = []
            try store.forEachVectorBlock(for: descriptorV1, maximumRows: maximumRows) { block in
                #expect(block.count <= maximumRows)
                streamed.append(contentsOf: block.uids)
                let scores = ReferenceDotProductScorer().rank(block: block, query: [1, 0, 0, 0], limit: block.count)
                #expect(scores.results.allSatisfy { $0.score == 1 })
            }
            #expect(streamed == uids)
        }
    }

    @Test func vectorBlockPagesAdvancePastAnEntireCorruptVolume() throws {
        try withStore { store, url in
            let uids = ["a", "b"].flatMap { volume in
                ["first", "last"].map { PhotoUID(volumeID: volume, nodeID: $0) }
            }
            store.upsert(uids.map { MLEmbeddingRecord(uid: $0, descriptor: descriptorV1, vector: [1, 0, 0, 0]) })
            var handle: OpaquePointer?
            #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
            defer { sqlite3_close(handle) }
            #expect(
                sqlite3_exec(handle, "UPDATE ml_embeddings SET vector=X'00' WHERE volume_id='a';", nil, nil, nil)
                    == SQLITE_OK)

            var streamed: [PhotoUID] = []
            try store.forEachVectorBlock(for: descriptorV1, maximumRows: 2) { streamed.append(contentsOf: $0.uids) }
            #expect(streamed == Array(uids.suffix(2)))
            #expect(store.count(for: descriptorV1) == 2)
        }
    }

    @Test func vectorBlockPagesKeepCursorStableAcrossInterleavedWrites() throws {
        try withStore { store, _ in
            let first = PhotoUID(volumeID: "a", nodeID: "first")
            let cursor = PhotoUID(volumeID: "a", nodeID: "last")
            let removed = PhotoUID(volumeID: "b", nodeID: "first")
            let last = PhotoUID(volumeID: "b", nodeID: "last")
            store.upsert(
                [first, cursor, removed, last].map {
                    MLEmbeddingRecord(uid: $0, descriptor: descriptorV1, vector: [1, 0, 0, 0])
                })
            let insertedAfterCursor = PhotoUID(volumeID: "b", nodeID: "inserted")
            var pages: [[PhotoUID]] = []
            try store.forEachVectorBlock(for: descriptorV1, maximumRows: 2) { block in
                pages.append(block.uids)
                guard pages.count == 1 else { return }
                // Page callbacks run outside the lock. Deleting the cursor must not shift later pages.
                store.remove(uids: [first, cursor, removed], descriptor: descriptorV1)
                store.upsert(
                    [PhotoUID(volumeID: "a", nodeID: "before"), insertedAfterCursor].map {
                        MLEmbeddingRecord(uid: $0, descriptor: descriptorV1, vector: [1, 0, 0, 0])
                    })
            }
            #expect(pages == [[first, cursor], [insertedAfterCursor, last]])
        }
    }

    @Test(arguments: [1, 2, 3])
    func vectorStreamRejectsStepFailureWithoutPublishingTheFailedPage(maximumRows: Int) throws {
        try withStore { store, url in
            store.upsert(["a", "b", "fail", "z"].map { record($0, descriptorV1, [1, 0, 0, 0]) })
            try SQLiteMLIndexReadFailureFixture.install(at: url)
            var visited: [PhotoUID] = []
            #expect(throws: MLIndexStoreReadError.storageUnavailable) {
                try store.forEachVectorBlock(for: descriptorV1, maximumRows: maximumRows) {
                    visited.append(contentsOf: $0.uids)
                }
            }
            #expect(visited == (maximumRows < 3 ? [uid("a"), uid("b")] : []))
        }
    }

    @Test func vectorStreamRejectsClosedStorage() throws {
        try withStore { store, _ in
            store.close()
            #expect(throws: MLIndexStoreReadError.storageUnavailable) {
                try store.forEachVectorBlock(for: descriptorV1, maximumRows: 2) { _ in
                    Issue.record("Closed storage must not publish a block")
                }
            }
        }
    }

    @Test func vectorStreamRejectsPrepareFailureAfterACompletedPage() throws {
        try withStore { store, url in
            store.upsert(["a", "b"].map { record($0, descriptorV1, [1, 0, 0, 0]) })
            var handle: OpaquePointer?
            try #require(sqlite3_open(url.path, &handle) == SQLITE_OK)
            defer { sqlite3_close(handle) }
            var visited: [PhotoUID] = []
            #expect(throws: MLIndexStoreReadError.storageUnavailable) {
                try store.forEachVectorBlock(for: descriptorV1, maximumRows: 1) { block in
                    visited.append(contentsOf: block.uids)
                    #expect(sqlite3_exec(handle, "DROP TABLE ml_embeddings;", nil, nil, nil) == SQLITE_OK)
                }
            }
            #expect(visited == [uid("a")])
        }
    }

    @Test func generationChangesOnlyWhenVectorStateChangesAndSurvivesReopen() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cipher = TestMLVectorCipher()
        let first = try #require(SQLiteMLIndexStore(url: url, cipher: cipher))
        #expect(first.generation(for: descriptorV1) == 0)
        first.upsert([record("a0", descriptorV1, [1, 0, 0, 0])])
        let insertedGeneration = first.generation(for: descriptorV1)
        #expect(insertedGeneration > 0)
        first.upsert([record("a0", descriptorV1, [9, 9, 9, 9])])
        #expect(first.generation(for: descriptorV1) == insertedGeneration)
        first.close()

        let reopened = try #require(SQLiteMLIndexStore(url: url, cipher: cipher))
        defer { reopened.close() }
        #expect(reopened.generation(for: descriptorV1) == insertedGeneration)
        reopened.remove(uid: uid("a0"), descriptor: descriptorV1)
        #expect(reopened.generation(for: descriptorV1) > insertedGeneration)
    }

    @Test func failureStateIsDurableAndSuccessfulEmbeddingClearsIt() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cipher = TestMLVectorCipher()
        let failedUID = uid("failed")
        let first = try #require(SQLiteMLIndexStore(url: url, cipher: cipher))
        #expect(
            first.recordFailures([
                MLIndexFailureRecord(
                    uid: failedUID,
                    descriptor: descriptorV1,
                    kind: .transient,
                    attempts: 2,
                    updatedAt: Date(timeIntervalSince1970: 10)
                )
            ]))
        first.close()

        let reopened = try #require(SQLiteMLIndexStore(url: url, cipher: cipher))
        defer { reopened.close() }
        #expect(try reopened.failureRecords(for: descriptorV1, from: [failedUID])[failedUID]?.attempts == 2)
        reopened.upsert([record("failed", descriptorV1, [1, 0, 0, 0])])
        #expect(try reopened.failureRecords(for: descriptorV1, from: [failedUID]).isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func smokeTwentyThousandUpsertAndLoad() throws {
        try withStore { store, _ in
            let dimension = 64
            let descriptor = MLModelDescriptor(identifier: "smoke", version: 1, embeddingDimension: dimension)
            let batchSize = 2_000
            for batch in 0..<10 {
                let records = (0..<batchSize).map { i -> MLEmbeddingRecord in
                    let n = batch * batchSize + i
                    var vector = ContiguousArray<Float32>(repeating: 0, count: dimension)
                    vector[n % dimension] = Float32(n)
                    return MLEmbeddingRecord(
                        uid: PhotoUID(volumeID: "vol1", nodeID: String(format: "n%06d", n)),
                        descriptor: descriptor,
                        vector: vector,
                        timestamp: Date(timeIntervalSince1970: 1_000)
                    )
                }
                let report = store.upsert(records)
                #expect(report.indexed == batchSize)
            }
            #expect(store.count(for: descriptor) == 20_000)

            let block = store.vectorBlock(for: descriptor)
            #expect(block.count == 20_000)

            var query = ContiguousArray<Float32>(repeating: 0, count: dimension)
            query[0] = 1
            let results = ReferenceDotProductScorer().rank(block: block, query: query, limit: 5)
            #expect(results.count == 5)
            // Highest score: the largest n hitting slot 0 (n % 64 == 0) to n = 19_968.
            #expect(results.results.first?.uid.nodeID == "n019968")

            // Membership over the whole set stays chunked and index-only.
            let probes = (0..<20_000).map { PhotoUID(volumeID: "vol1", nodeID: String(format: "n%06d", $0)) }
            let readResult10 = try store.indexedUIDs(for: descriptor, from: probes).count == 20_000
            #expect(readResult10)
        }
    }
}
