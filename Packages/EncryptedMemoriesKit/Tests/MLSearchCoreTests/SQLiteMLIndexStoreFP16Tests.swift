import CryptoKit
import Foundation
import PhotosCore
import SQLite3
import Testing

@testable import MLSearchCore

/// Structural guarantees of the binary16 persistent index: footprint, warm-search block reuse,
/// ranking parity within fp16 tolerance, corrupt-row safety, and clean schema reset.
@Suite struct SQLiteMLIndexStoreFP16Tests {
    private final class CountingCipher: MLVectorCipher, @unchecked Sendable {
        private let backing = TestMLVectorCipher()
        private let lock = NSLock()
        private(set) var opens = 0

        func seal(_ plaintext: Data, context: MLVectorCipherContext) throws -> Data {
            try backing.seal(plaintext, context: context)
        }
        func open(_ ciphertext: Data, context: MLVectorCipherContext) throws -> Data {
            lock.withLock { opens += 1 }
            return try backing.open(ciphertext, context: context)
        }
        func sealedByteCount(forPlaintextByteCount plaintextByteCount: Int) -> Int? {
            backing.sealedByteCount(forPlaintextByteCount: plaintextByteCount)
        }
        var openCount: Int { lock.withLock { opens } }
    }

    private struct AuthenticatingCipher: MLVectorCipher {
        struct AuthenticationFailed: Error {}

        func seal(_ plaintext: Data, context: MLVectorCipherContext) throws -> Data {
            plaintext + Data(SHA256.hash(data: plaintext).prefix(16))
        }

        func open(_ ciphertext: Data, context: MLVectorCipherContext) throws -> Data {
            guard ciphertext.count >= 16 else { throw AuthenticationFailed() }
            let plaintext = ciphertext.dropLast(16)
            let expected = Data(SHA256.hash(data: plaintext).prefix(16))
            guard Data(ciphertext.suffix(16)) == expected else { throw AuthenticationFailed() }
            return Data(plaintext)
        }

        func sealedByteCount(forPlaintextByteCount plaintextByteCount: Int) -> Int? {
            plaintextByteCount + 16
        }
    }

    private final class CountingStore: MLIndexStore, @unchecked Sendable {
        private let backing: any MLIndexStore
        private let lock = NSLock()
        private(set) var blockLoads = 0

        init(_ backing: any MLIndexStore) { self.backing = backing }

        var blockLoadCount: Int { lock.withLock { blockLoads } }

        func upsert(_ records: [MLEmbeddingRecord]) -> MLIndexBatchReport { backing.upsert(records) }
        func indexedUIDs(for descriptor: MLModelDescriptor, from uids: [PhotoUID]) throws -> Set<PhotoUID> {
            try backing.indexedUIDs(for: descriptor, from: uids)
        }
        func reconcileTrackedUIDs(
            currentAuthoritativeUIDs: [PhotoUID],
            previousAuthoritativeUIDs: [PhotoUID]?,
            descriptor: MLModelDescriptor
        ) -> Bool {
            backing.reconcileTrackedUIDs(
                currentAuthoritativeUIDs: currentAuthoritativeUIDs,
                previousAuthoritativeUIDs: previousAuthoritativeUIDs,
                descriptor: descriptor
            )
        }
        func forEachVectorBlock(
            for descriptor: MLModelDescriptor,
            maximumRows: Int,
            _ body: (MLVectorBlock) throws -> Void
        ) throws {
            try backing.forEachVectorBlock(for: descriptor, maximumRows: maximumRows) { block in
                lock.withLock { blockLoads += 1 }
                try body(block)
            }
        }
        func remove(uids: [PhotoUID], descriptor: MLModelDescriptor) {
            backing.remove(uids: uids, descriptor: descriptor)
        }
        func removeAll(for descriptor: MLModelDescriptor) -> Bool {
            backing.removeAll(for: descriptor)
        }
        func count(for descriptor: MLModelDescriptor) -> Int { backing.count(for: descriptor) }
        func generation(for descriptor: MLModelDescriptor) -> UInt64 { backing.generation(for: descriptor) }
        func recordFailures(_ records: [MLIndexFailureRecord]) -> Bool { backing.recordFailures(records) }
        func failureRecords(
            for descriptor: MLModelDescriptor, from uids: [PhotoUID]
        ) throws -> [PhotoUID: MLIndexFailureRecord] { try backing.failureRecords(for: descriptor, from: uids) }
    }

    private struct FixedTextEncoder: MLTextQueryEncoder {
        func encode(text: String, descriptor: MLModelDescriptor) async throws -> ContiguousArray<Float32> {
            var vector = ContiguousArray<Float32>(repeating: 0, count: descriptor.embeddingDimension)
            vector[0] = 1
            return vector
        }
    }

    private func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: "vol1", nodeID: id) }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-fp16-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func databaseFileBytes(at url: URL) -> Int64 {
        ["", "-wal", "-shm"].reduce(0) { total, suffix in
            let path = url.path + suffix
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            return total + size
        }
    }

    /// Deterministic pseudo-random unit-ish vector with fp16-inexact components.
    private func vector(seed: Int, dimension: Int) -> ContiguousArray<Float32> {
        var state = UInt64(bitPattern: Int64(seed)) &* 0x9E37_79B9_7F4A_7C15 &+ 1
        var vector = ContiguousArray<Float32>()
        vector.reserveCapacity(dimension)
        for _ in 0..<dimension {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            vector.append((Float32(state >> 40) / Float32(1 << 24)) - 0.5)
        }
        return MLVectorNormalization.normalized(vector) ?? vector
    }

    @Test(.timeLimit(.minutes(2))) func twentyThousandFP16RowsHalveTheFloat32Footprint() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(SQLiteMLIndexStore.databaseFileName)
        let dimension = 512
        let rows = 20_000
        let descriptor = MLModelDescriptor(identifier: "fp16-size", version: 1, embeddingDimension: dimension)

        let store = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        let insertStart = ContinuousClock.now
        for batch in 0..<10 {
            let records = (0..<(rows / 10)).map { offset -> MLEmbeddingRecord in
                let n = batch * (rows / 10) + offset
                return MLEmbeddingRecord(
                    uid: PhotoUID(volumeID: "vol1", nodeID: String(format: "n%06d", n)),
                    descriptor: descriptor,
                    vector: vector(seed: n, dimension: dimension),
                    timestamp: Date(timeIntervalSince1970: 1_000)
                )
            }
            #expect(store.upsert(records).indexed == rows / 10)
        }
        let insertDuration = ContinuousClock.now - insertStart
        #expect(store.count(for: descriptor) == rows)

        // Full load streams every row back into one packed block (fp16 to Float32 widening).
        let loadStart = ContinuousClock.now
        let block = store.vectorBlock(for: descriptor)
        let loadDuration = ContinuousClock.now - loadStart
        #expect(block.count == rows)
        store.close()
        print("[fp16-index] 20k×\(dimension) insert=\(insertDuration) blockLoad=\(loadDuration)")

        let actualBytes = databaseFileBytes(at: url)
        // The fp16 database must remain below the equivalent Float32 payload size.
        let float32PayloadFloor = Int64(rows * dimension * MemoryLayout<Float32>.size)
        // The absolute bound includes row keys, indexes, page slack, and the WAL remainder.
        let fp16Bound = Int64(rows * (dimension * MLFloat16Codec.bytesPerElement + 512))
        #expect(actualBytes > 0)
        #expect(
            actualBytes < float32PayloadFloor,
            "fp16 database (\(actualBytes) B) must undercut the raw Float32 payload (\(float32PayloadFloor) B)")
        #expect(
            actualBytes <= fp16Bound,
            "fp16 database (\(actualBytes) B) exceeds payload+overhead bound (\(fp16Bound) B)")
    }

    @Test func searchLoadsOnlyBoundedBlocksAndDoesNotRetainTheEpoch() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(SQLiteMLIndexStore.databaseFileName)
        let descriptor = MLModelDescriptor(identifier: "fp16-warm", version: 1, embeddingDimension: 8)
        let sqlite = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        defer { sqlite.close() }
        let store = CountingStore(sqlite)
        _ = store.upsert(
            (0..<32).map {
                MLEmbeddingRecord(uid: uid("a\($0)"), descriptor: descriptor, vector: vector(seed: $0, dimension: 8))
            })

        let engine = MLSemanticSearchEngine(
            store: store,
            encoder: FixedTextEncoder(),
            scorer: ReferenceDotProductScorer(),
            queryBlockRowLimit: 8
        )
        _ = try await engine.search(MLSearchQuery(descriptor: descriptor, queryText: "warm one", limit: 5))
        _ = try await engine.search(MLSearchQuery(descriptor: descriptor, queryText: "warm two", limit: 5))
        // Four rows per 8-row block are streamed for each search. The second search does not
        // retain the first epoch-sized matrix.
        #expect(store.blockLoadCount == 8)

        // A vector-state change is visible on the next streamed search without a stale snapshot.
        _ = store.upsert([
            MLEmbeddingRecord(uid: uid("fresh"), descriptor: descriptor, vector: vector(seed: 99, dimension: 8))
        ])
        _ = try await engine.search(MLSearchQuery(descriptor: descriptor, queryText: "warm three", limit: 5))
        #expect(store.blockLoadCount == 13)
    }

    @Test func fp16RankingMatchesFloat32ReferenceWithinToleranceAndKeepsTieOrder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(SQLiteMLIndexStore.databaseFileName)
        let dimension = 64
        let descriptor = MLModelDescriptor(identifier: "fp16-parity", version: 1, embeddingDimension: dimension)
        let sqlite = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        defer { sqlite.close() }
        let memory = InMemoryMLIndexStore()

        var records = (0..<200).map {
            MLEmbeddingRecord(
                uid: uid(String(format: "r%03d", $0)), descriptor: descriptor,
                vector: vector(seed: $0, dimension: dimension))
        }
        // Two identical rows (exact tie): ties must break by deterministic row (key) order in
        // both stores. Keys sort behind every "r…" uid in insertion-independent key order.
        let tieVector = vector(seed: 4_242, dimension: dimension)
        records.append(MLEmbeddingRecord(uid: uid("tie-b"), descriptor: descriptor, vector: tieVector))
        records.append(MLEmbeddingRecord(uid: uid("tie-a"), descriptor: descriptor, vector: tieVector))
        sqlite.upsert(records)
        memory.upsert(records)

        let query = vector(seed: 31_337, dimension: dimension)
        let scorer = ReferenceDotProductScorer()
        let fp16Results = scorer.rank(block: sqlite.vectorBlock(for: descriptor), query: query, limit: records.count)
        let referenceResults = scorer.rank(
            block: memory.vectorBlock(for: descriptor), query: query, limit: records.count)

        #expect(fp16Results.count == referenceResults.count)
        // Scores agree within fp16 quantization tolerance for every row.
        let referenceByUID = Dictionary(uniqueKeysWithValues: referenceResults.results.map { ($0.uid, $0.score) })
        for result in fp16Results.results {
            let reference = try #require(referenceByUID[result.uid])
            #expect(abs(result.score - reference) < 2e-3, "\(result.uid.nodeID)")
        }
        // Order agrees wherever the reference scores are separated by more than the tolerance.
        for (index, reference) in referenceResults.results.enumerated().dropLast() {
            let next = referenceResults.results[index + 1]
            guard reference.score - next.score > 4e-3 else { continue }
            let fp16IndexA = try #require(fp16Results.results.firstIndex { $0.uid == reference.uid })
            let fp16IndexB = try #require(fp16Results.results.firstIndex { $0.uid == next.uid })
            #expect(
                fp16IndexA < fp16IndexB, "well-separated pair reordered: \(reference.uid.nodeID) vs \(next.uid.nodeID)")
        }
        // Exact ties keep deterministic key order (tie-a < tie-b) in both stores.
        for results in [fp16Results, referenceResults] {
            let tieA = try #require(results.results.firstIndex { $0.uid == uid("tie-a") })
            let tieB = try #require(results.results.firstIndex { $0.uid == uid("tie-b") })
            #expect(tieA < tieB)
        }
    }

    @Test func corruptRowsAreSkippedWithoutSpendingDecryption() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(SQLiteMLIndexStore.databaseFileName)
        let dimension = 8
        let descriptor = MLModelDescriptor(identifier: "fp16-corrupt", version: 1, embeddingDimension: dimension)
        let cipher = CountingCipher()
        let store = try #require(SQLiteMLIndexStore(url: url, cipher: cipher))
        defer { store.close() }
        store.upsert(
            (0..<4).map {
                MLEmbeddingRecord(
                    uid: uid("a\($0)"), descriptor: descriptor, vector: vector(seed: $0, dimension: dimension))
            })

        // Corrupt one row's blob to a truncated length directly in SQLite (out-of-band
        // corruption, as a partial write or bit rot would produce).
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(
            sqlite3_exec(handle, "UPDATE ml_embeddings SET vector = x'DEAD' WHERE node_id = 'a1';", nil, nil, nil)
                == SQLITE_OK)

        let opensBefore = cipher.openCount
        let block = store.vectorBlock(for: descriptor)
        // The truncated row is invisible, the healthy rows load - and the wrong-sized blob
        // was rejected by the byte-count check before any decryption.
        #expect(block.count == 3)
        #expect(!block.uids.contains(uid("a1")))
        #expect(cipher.openCount - opensBefore == 3)
        #expect(store.vectorBlock(for: descriptor).count == 3)

        // The read purges the invalid derived row. Normal membership now schedules it again.
        #expect(try store.contains(uid: uid("a1"), descriptor: descriptor) == false)
        #expect(store.count(for: descriptor) == 3)
        store.upsert([
            MLEmbeddingRecord(uid: uid("a1"), descriptor: descriptor, vector: vector(seed: 1, dimension: dimension))
        ])
        #expect(store.vectorBlock(for: descriptor).count == 4)
    }

    @Test func authenticationFailurePurgesRowAndNormalUpsertRebuildsIt() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(SQLiteMLIndexStore.databaseFileName)
        let descriptor = MLModelDescriptor(identifier: "fp16-auth-corrupt", version: 1, embeddingDimension: 8)
        let store = try #require(SQLiteMLIndexStore(url: url, cipher: AuthenticatingCipher()))
        defer { store.close() }
        store.upsert(
            (0..<2).map {
                MLEmbeddingRecord(uid: uid("a\($0)"), descriptor: descriptor, vector: vector(seed: $0, dimension: 8))
            })
        let generationBefore = store.generation(for: descriptor)

        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        var read: OpaquePointer?
        #expect(
            sqlite3_prepare_v2(handle, "SELECT vector FROM ml_embeddings WHERE node_id='a1';", -1, &read, nil)
                == SQLITE_OK)
        #expect(sqlite3_step(read) == SQLITE_ROW)
        let byteCount = Int(sqlite3_column_bytes(read, 0))
        let bytes = try #require(sqlite3_column_blob(read, 0))
        var corrupted = Data(bytes: bytes, count: byteCount)
        corrupted[0] ^= 0x01
        sqlite3_finalize(read)
        var write: OpaquePointer?
        #expect(
            sqlite3_prepare_v2(handle, "UPDATE ml_embeddings SET vector=? WHERE node_id='a1';", -1, &write, nil)
                == SQLITE_OK)
        _ = corrupted.withUnsafeBytes {
            sqlite3_bind_blob(
                write, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        #expect(sqlite3_step(write) == SQLITE_DONE)
        sqlite3_finalize(write)

        #expect(store.vectorBlock(for: descriptor).count == 1)
        #expect(try store.contains(uid: uid("a1"), descriptor: descriptor) == false)
        #expect(store.generation(for: descriptor) > generationBefore)

        #expect(
            store.upsert([
                MLEmbeddingRecord(uid: uid("a1"), descriptor: descriptor, vector: vector(seed: 1, dimension: 8))
            ]).indexed == 1)
        #expect(store.vectorBlock(for: descriptor).count == 2)
    }

    @Test func staleSchemaVersionResetsCleanlyAndReindexIsIdempotent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(SQLiteMLIndexStore.databaseFileName)
        let dimension = 8
        let descriptor = MLModelDescriptor(identifier: "fp16-reset", version: 1, embeddingDimension: dimension)
        let records = (0..<6).map {
            MLEmbeddingRecord(
                uid: uid("a\($0)"), descriptor: descriptor, vector: vector(seed: $0, dimension: dimension))
        }

        let first = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        first.upsert(records)
        #expect(first.count(for: descriptor) == 6)
        first.close()

        // Simulate a database created with the Float32 schema.
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "PRAGMA user_version=2;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        // Reopen: version mismatch to the ML-only schema resets to empty (derived data, no
        // migration machinery). Reindexing the same records is a clean, idempotent rebuild.
        let reopened = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        defer { reopened.close() }
        #expect(reopened.count(for: descriptor) == 0)
        #expect(reopened.upsert(records).indexed == 6)
        let replay = reopened.upsert(records)
        #expect(replay.indexed == 0)
        #expect(replay.skippedAlreadyIndexed == 6)
        #expect(reopened.vectorBlock(for: descriptor).count == 6)
    }
}
