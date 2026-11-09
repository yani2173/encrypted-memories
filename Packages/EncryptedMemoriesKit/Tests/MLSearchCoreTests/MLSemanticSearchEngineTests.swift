import Foundation
import PhotosCore
import Testing

@testable import MLSearchCore

@Suite struct MLSemanticSearchEngineTests {
    private let descriptor = MLModelDescriptor(identifier: "test-model", version: 1, embeddingDimension: 3)

    private func uid(_ value: String) -> PhotoUID {
        PhotoUID(volumeID: "v", nodeID: value)
    }

    private func unitVector(withQueryScore score: Float32) -> ContiguousArray<Float32> {
        [score, sqrt(max(0, 1 - score * score)), 0]
    }

    private struct Encoder: MLTextQueryEncoder {
        let vector: ContiguousArray<Float32>
        func encode(text: String, descriptor: MLModelDescriptor) async throws -> ContiguousArray<Float32> {
            vector
        }
    }

    private final class PreemptionProbe: MLVectorScorer, @unchecked Sendable {
        private let lock = NSLock()
        private var blocks = 0
        var scoredBlocks: Int { lock.withLock { blocks } }
        func score(block: MLVectorBlock, query: ContiguousArray<Float32>, into scores: inout [Float32]) {
            ReferenceDotProductScorer().score(block: block, query: query, into: &scores)
            lock.withLock { blocks += 1 }
        }
    }

    @Test func preemptedSearchStopsAtTheNextBlockAndNeverReturnsPartialResults() async throws {
        let store = InMemoryMLIndexStore()
        store.upsert(
            (0..<8).map {
                MLEmbeddingRecord(uid: uid("\($0)"), descriptor: descriptor, vector: [1, 0, 0])
            })
        let probe = PreemptionProbe()
        let engine = MLSemanticSearchEngine(
            store: store, encoder: Encoder(vector: [1, 0, 0]), scorer: probe, queryBlockRowLimit: 2
        )
        await #expect(throws: CancellationError.self) {
            try await engine.search(
                MLSearchQuery(descriptor: descriptor, queryText: "fixture", limit: 8),
                shouldContinue: { probe.scoredBlocks == 0 }
            )
        }
        #expect(probe.scoredBlocks == 1)
        let resumed = try await engine.search(MLSearchQuery(descriptor: descriptor, queryText: "fixture", limit: 8))
        #expect(resumed.results.count == 8)
    }

    private final class ReadCountingCipher: MLVectorCipher, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var reads: Int { lock.withLock { count } }
        func seal(_ plaintext: Data, context: MLVectorCipherContext) throws -> Data {
            try TestMLVectorCipher().seal(plaintext, context: context)
        }
        func open(_ ciphertext: Data, context: MLVectorCipherContext) throws -> Data {
            lock.withLock { count += 1 }
            return try TestMLVectorCipher().open(ciphertext, context: context)
        }
    }

    private actor CountingPromptEncoder: MLTextQueryEncoder {
        private(set) var count = 0
        func encode(text: String, descriptor: MLModelDescriptor) async throws -> ContiguousArray<Float32> {
            count += 1
            return text == "query-50" ? [0, 4, 0] : [4, 0, 0]
        }
    }

    @Test func batchedSuggestionsMatchIndependentQueriesIncludingTiesAndLimits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cipher = ReadCountingCipher()
        let encoder = CountingPromptEncoder()
        let store = try #require(
            SQLiteMLIndexStore(url: directory.appendingPathComponent("index.sqlite"), cipher: cipher))
        defer { store.close() }
        store.upsert(
            (0..<601).map {
                MLEmbeddingRecord(
                    uid: uid("item-\($0)"), descriptor: descriptor,
                    vector: $0 % 3 == 0 ? [0, 1, 0] : [1, 0, 0])
            })
        let engine = MLSemanticSearchEngine(store: store, encoder: encoder, scorer: ReferenceDotProductScorer())
        let queries = [0, 6, 50, 400].map {
            MLSearchQuery(descriptor: descriptor, queryText: "query-\($0)", limit: $0)
        }
        var expected: [[MLSearchResult]] = []
        for query in queries { expected.append(try await engine.search(query).results) }
        let priorReads = cipher.reads
        let actual = try await engine.searchBatch(queries)
        #expect(actual.results.map(\.results) == expected)
        #expect(actual.results.map(\.queryText) == queries.map(\.queryText))
        #expect(cipher.reads - priorReads == 601, "each encrypted row is read once for the whole batch")
        #expect(actual.scannedUIDs.isEmpty, "a skipped prompt cannot authorize previews")
        let checked = try await engine.searchBatch(Array(queries.dropFirst()))
        #expect(checked.scannedUIDs.count == 601)
        #expect((0..<601).allSatisfy { checked.scannedUIDs.contains(uid("item-\($0)")) })
        let encoded = await encoder.count
        _ = try await engine.searchBatch(queries)
        #expect(await encoder.count == encoded)
        await engine.purgePromptEmbeddings()
        _ = try await engine.searchBatch(queries)
        #expect(await encoder.count == encoded + queries.count)
    }

    @Test func scanMembershipPreservesExactUIDEqualityAndSnapshotIsolation() {
        let original =
            (0..<1_031).map {
                PhotoUID(volumeID: "volume-\($0 % 7)", nodeID: "node-\($0)")
            } + [
                PhotoUID(volumeID: "é", nodeID: "🌿"),
                PhotoUID(volumeID: "e\u{301}", nodeID: "🌿"),
                PhotoUID(volumeID: "", nodeID: ""),
            ]
        let reference = Set(original)
        var membership = MLScannedUIDMembership()
        for start in stride(from: 0, to: original.count, by: 256) {
            membership.formUnion(original[start..<min(original.count, start + 256)])
        }
        #expect(membership.count == reference.count)
        let probes = original + original.map { PhotoUID(volumeID: $0.volumeID + "-other", nodeID: $0.nodeID) }
        for candidate in probes { #expect(membership.contains(candidate) == reference.contains(candidate)) }

        let completed = membership
        let later = PhotoUID(volumeID: "volume-0", nodeID: "indexed-after-batch")
        membership.formUnion([later])
        #expect(!completed.contains(later), "later indexing cannot authorize an unchecked preview")
        let current = Array(original.prefix(300)) + [later]
        let restricted = completed.intersection(current)
        let expected = reference.intersection(current)
        #expect(restricted.count == expected.count)
        for candidate in probes + [later] { #expect(restricted.contains(candidate) == expected.contains(candidate)) }
        #expect(MLScannedUIDMembership().intersection(original).isEmpty)
    }

    private struct DualEncoder: MLAssetEmbedder, MLTextQueryEncoder {
        func embed(uid: PhotoUID, descriptor: MLModelDescriptor) async -> MLEmbeddingOutcome {
            .embedded(uid.nodeID == "tree" ? [1, 0, 0] : [0, 1, 0])
        }

        func encode(text: String, descriptor: MLModelDescriptor) async throws -> ContiguousArray<Float32> {
            [1, 0, 0]
        }
    }

    @Test func sqliteSearchPreservesRankingAndTiesAcrossVolumeBoundaries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(
            SQLiteMLIndexStore(url: directory.appendingPathComponent("index.sqlite"), cipher: TestMLVectorCipher())
        )
        defer { store.close() }
        let uids = ["a", "b", "c"].flatMap { volume in
            ["first", "last"].map { PhotoUID(volumeID: volume, nodeID: $0) }
        }
        store.upsert(
            uids.enumerated().map { index, uid in
                MLEmbeddingRecord(uid: uid, descriptor: descriptor, vector: index == 2 ? [0, 1, 0] : [1, 0, 0])
            })
        var reference: [MLSearchResult]?
        for pageSize in [1, 2, 3, MLSemanticSearchEngine.defaultQueryBlockRowLimit] {
            let engine = MLSemanticSearchEngine(
                store: store,
                encoder: Encoder(vector: [1, 0, 0]),
                scorer: ReferenceDotProductScorer(),
                queryBlockRowLimit: pageSize
            )
            let result = try await engine.search(MLSearchQuery(descriptor: descriptor, queryText: "fixture", limit: 4))
            #expect(result.results.map(\.uid) == [uids[0], uids[1], uids[3], uids[4]])
            if let reference { #expect(result.results == reference) }
            reference = result.results
        }
    }

    @Test(arguments: [1, 2, 3])
    func sqliteReadFailureNeverReturnsSuccessfulPartialSearch(maximumRows: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let store = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        defer { store.close() }
        store.upsert(
            ["a", "b", "fail", "z"].map {
                MLEmbeddingRecord(uid: uid($0), descriptor: descriptor, vector: [1, 0, 0])
            })
        try SQLiteMLIndexReadFailureFixture.install(at: url)
        let engine = MLSemanticSearchEngine(
            store: store, encoder: Encoder(vector: [1, 0, 0]), scorer: ReferenceDotProductScorer(),
            queryBlockRowLimit: maximumRows
        )
        await #expect(throws: MLIndexStoreReadError.storageUnavailable) {
            try await engine.search(MLSearchQuery(descriptor: descriptor, queryText: "fixture", limit: 4))
        }
    }

    private final class SelfHealingStore: MLIndexStore, @unchecked Sendable {
        private let backing = InMemoryMLIndexStore()
        private let invalidUID: PhotoUID
        private let lock = NSLock()
        private var didHeal = false
        private var loads = 0

        init(invalidUID: PhotoUID) { self.invalidUID = invalidUID }

        var blockLoads: Int { lock.withLock { loads } }
        func upsert(_ records: [MLEmbeddingRecord]) -> MLIndexBatchReport { backing.upsert(records) }
        func indexedUIDs(for descriptor: MLModelDescriptor, from uids: [PhotoUID]) throws -> Set<PhotoUID> {
            backing.indexedUIDs(for: descriptor, from: uids)
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
            let shouldHeal = lock.withLock {
                loads += 1
                if didHeal { return false }
                didHeal = true
                return true
            }
            if shouldHeal { backing.remove(uids: [invalidUID], descriptor: descriptor) }
            try body(backing.vectorBlock(for: descriptor))
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
        ) throws -> [PhotoUID: MLIndexFailureRecord] { backing.failureRecords(for: descriptor, from: uids) }
    }

    @Test func normalizesQueryAndRanksSharedIndex() async throws {
        let store = InMemoryMLIndexStore()
        _ = store.upsert([
            MLEmbeddingRecord(uid: uid("tree"), descriptor: descriptor, vector: [1, 0, 0]),
            MLEmbeddingRecord(uid: uid("water"), descriptor: descriptor, vector: [0, 1, 0]),
        ])
        let engine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [9, 0, 0]),
            scorer: ReferenceDotProductScorer()
        )

        let result = try await engine.search(MLSearchQuery(descriptor: descriptor, queryText: "trees", limit: 2))
        #expect(result.results.map(\.uid.nodeID) == ["tree", "water"])
        #expect(abs((result.results.first?.score ?? 0) - 1) < 0.0001)
        #expect(result.durationMs != nil)
    }

    @Test func calibratedPolicyChoosesRelevantCountInsteadOfFillingCandidateLimit() async throws {
        let store = InMemoryMLIndexStore()
        let relevant = (0..<13).map {
            MLEmbeddingRecord(
                uid: uid("horse-\($0)"),
                descriptor: descriptor,
                vector: unitVector(withQueryScore: 0.10 - Float32($0) * 0.001)
            )
        }
        let irrelevant = (0..<388).map {
            MLEmbeddingRecord(
                uid: uid("background-\($0)"),
                descriptor: descriptor,
                vector: unitVector(withQueryScore: 0.04 - Float32($0 % 10) * 0.001)
            )
        }
        #expect(store.upsert(relevant + irrelevant).indexed == 401)
        let engine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [1, 0, 0]),
            scorer: ReferenceDotProductScorer(),
            relevancePolicy: MLModelCatalogEntry.sigLIP2Base256.relevancePolicy,
            queryBlockRowLimit: 37
        )

        let result = try await engine.search(
            MLSearchQuery(descriptor: descriptor, queryText: "horse", limit: 400)
        )

        #expect(result.count == 13)
        #expect(result.results.allSatisfy { $0.uid.nodeID.hasPrefix("horse-") })
    }

    @Test func calibratedPolicyReturnsNoSemanticMatchesWhenBestScoreIsTooWeak() async throws {
        let store = InMemoryMLIndexStore()
        #expect(
            store.upsert(
                (0..<50).map {
                    MLEmbeddingRecord(
                        uid: uid("nearest-but-irrelevant-\($0)"),
                        descriptor: descriptor,
                        vector: unitVector(withQueryScore: 0.05 - Float32($0) * 0.0005)
                    )
                }
            ).indexed == 50)
        let engine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [1, 0, 0]),
            scorer: ReferenceDotProductScorer(),
            relevancePolicy: MLModelCatalogEntry.sigLIP2Base256.relevancePolicy
        )

        let result = try await engine.search(
            MLSearchQuery(descriptor: descriptor, queryText: "elephant", limit: 400)
        )

        #expect(result.isEmpty)
    }

    @Test func streamedSearchSeesStoreChangesWithoutAStaleBlock() async throws {
        let store = InMemoryMLIndexStore()
        store.upsert([MLEmbeddingRecord(uid: uid("first"), descriptor: descriptor, vector: [1, 0, 0])])
        let engine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [1, 0, 0]),
            scorer: ReferenceDotProductScorer()
        )
        #expect(try await engine.search(MLSearchQuery(descriptor: descriptor, queryText: "x")).count == 1)

        store.upsert([MLEmbeddingRecord(uid: uid("second"), descriptor: descriptor, vector: [1, 0, 0])])
        #expect(try await engine.search(MLSearchQuery(descriptor: descriptor, queryText: "x")).count == 2)
    }

    @Test func selfHealingStreamDoesNotRetainAFullLibrarySnapshot() async throws {
        let invalid = uid("invalid")
        let store = SelfHealingStore(invalidUID: invalid)
        _ = store.upsert([
            MLEmbeddingRecord(uid: uid("valid"), descriptor: descriptor, vector: [1, 0, 0]),
            MLEmbeddingRecord(uid: invalid, descriptor: descriptor, vector: [0, 1, 0]),
        ])
        let engine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [1, 0, 0]),
            scorer: ReferenceDotProductScorer()
        )

        #expect(try await engine.search(MLSearchQuery(descriptor: descriptor, queryText: "first")).count == 1)
        #expect(try await engine.search(MLSearchQuery(descriptor: descriptor, queryText: "second")).count == 1)
        #expect(store.blockLoads == 2)
    }

    @Test func batchCoverageExcludesRowsRemovedDuringSelfHealing() async throws {
        let invalid = uid("invalid")
        let valid = uid("valid")
        let store = SelfHealingStore(invalidUID: invalid)
        _ = store.upsert([
            MLEmbeddingRecord(uid: valid, descriptor: descriptor, vector: [1, 0, 0]),
            MLEmbeddingRecord(uid: invalid, descriptor: descriptor, vector: [0, 1, 0]),
        ])
        let engine = MLSemanticSearchEngine(
            store: store, encoder: Encoder(vector: [1, 0, 0]), scorer: ReferenceDotProductScorer())
        let result = try await engine.searchBatch([MLSearchQuery(descriptor: descriptor, queryText: "fixture")])
        #expect(result.scannedUIDs.count == 1)
        #expect(result.scannedUIDs.contains(valid))
        #expect(!result.scannedUIDs.contains(invalid))
        #expect(result.results.first?.results.map(\.uid) == [valid])
        #expect(store.blockLoads == 1)
    }

    @Test func streamingKeepsRankingAndTieOrderAcrossBoundedBlocks() async throws {
        let store = InMemoryMLIndexStore()
        store.upsert(
            (0..<5).map {
                MLEmbeddingRecord(uid: uid("row-\($0)"), descriptor: descriptor, vector: [1, 0, 0])
            })
        let engine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [1, 0, 0]),
            scorer: ReferenceDotProductScorer(),
            queryBlockRowLimit: 2
        )

        let result = try await engine.search(
            MLSearchQuery(descriptor: descriptor, queryText: "same", limit: 4)
        )
        #expect(result.results.map(\.uid.nodeID) == ["row-0", "row-1", "row-2", "row-3"])
    }

    @Test func switchingDescriptorDoesNotReusePreviousModelBlock() async throws {
        let other = MLModelDescriptor(identifier: "other-model", version: 1, embeddingDimension: 3)
        let store = InMemoryMLIndexStore()
        store.upsert([
            MLEmbeddingRecord(uid: uid("first"), descriptor: descriptor, vector: [1, 0, 0]),
            MLEmbeddingRecord(uid: uid("second"), descriptor: other, vector: [1, 0, 0]),
            MLEmbeddingRecord(uid: uid("third"), descriptor: other, vector: [1, 0, 0]),
        ])
        let engine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [1, 0, 0]),
            scorer: ReferenceDotProductScorer()
        )

        #expect(try await engine.search(MLSearchQuery(descriptor: descriptor, queryText: "x")).count == 1)
        #expect(try await engine.search(MLSearchQuery(descriptor: other, queryText: "x")).count == 2)
        #expect(try await engine.search(MLSearchQuery(descriptor: descriptor, queryText: "x")).count == 1)
    }

    @Test func coverageDistinguishesSearchablePermanentAndPending() async throws {
        let store = InMemoryMLIndexStore()
        let indexed = uid("indexed")
        let permanent = uid("permanent")
        let pending = uid("pending")
        store.upsert([MLEmbeddingRecord(uid: indexed, descriptor: descriptor, vector: [1, 0, 0])])
        store.recordFailures([
            MLIndexFailureRecord(
                uid: permanent,
                descriptor: descriptor,
                kind: .permanent,
                reason: "unsupported",
                attempts: 1
            )
        ])
        let engine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [1, 0, 0]),
            scorer: ReferenceDotProductScorer()
        )

        let coverage = try await engine.coverage(for: descriptor, allAssets: [indexed, permanent, pending])
        #expect(coverage.indexed == 1)
        #expect(coverage.permanentlyUnindexable == 1)
        #expect(coverage.pending == 1)
        #expect(!coverage.isComplete)
    }

    @Test func coverageCountsDuplicateHostUIDsOnce() async throws {
        let store = InMemoryMLIndexStore()
        let indexed = uid("indexed")
        store.upsert([MLEmbeddingRecord(uid: indexed, descriptor: descriptor, vector: [1, 0, 0])])
        let engine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [1, 0, 0]),
            scorer: ReferenceDotProductScorer()
        )

        let coverage = try await engine.coverage(
            for: descriptor,
            allAssets: [indexed, indexed, uid("pending"), uid("pending")]
        )

        #expect(coverage.total == 2)
        #expect(coverage.indexed == 1)
        #expect(coverage.pending == 1)
    }

    @Test func rejectsEmptyInvalidAndWrongDimensionQueries() async {
        let store = InMemoryMLIndexStore()
        let emptyEngine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [1, 0, 0]),
            scorer: ReferenceDotProductScorer()
        )
        await #expect(throws: MLSemanticSearchError.emptyQuery) {
            try await emptyEngine.search(MLSearchQuery(descriptor: descriptor, queryText: "  "))
        }

        let zeroEngine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [0, 0, 0]),
            scorer: ReferenceDotProductScorer()
        )
        await #expect(throws: MLSemanticSearchError.invalidQueryEmbedding) {
            try await zeroEngine.search(MLSearchQuery(descriptor: descriptor, queryText: "x"))
        }

        let wrongEngine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [1, 0]),
            scorer: ReferenceDotProductScorer()
        )
        await #expect(throws: MLSemanticSearchError.queryDimensionMismatch(expected: 3, actual: 2)) {
            try await wrongEngine.search(MLSearchQuery(descriptor: descriptor, queryText: "x"))
        }
    }

    @Test func serviceUsesOneDescriptorForIndexCoverageAndSearch() async throws {
        let assets = [uid("water"), uid("tree")]
        let encoder = DualEncoder()
        let releases = ReleaseCounter()
        let service = MLSearchService(
            descriptor: descriptor,
            store: InMemoryMLIndexStore(),
            assetEmbedder: encoder,
            textEncoder: encoder,
            scorer: ReferenceDotProductScorer(),
            releaseInferenceResources: { releases.increment() }
        )

        let indexed = await service.index(assets)
        #expect(indexed.report.indexed == 2)
        #expect(releases.value == 1)
        #expect(try await service.coverage(for: assets).isComplete)
        let results = try await service.search("trees", limit: 1)
        #expect(results.descriptor == descriptor)
        #expect(results.results.map(\.uid.nodeID) == ["tree"])
        await service.releaseMemory()
        #expect(releases.value == 2)
    }

    @Test func quantumIndexingRetainsInferenceResourcesUntilRelease() async {
        let releases = ReleaseCounter()
        let encoder = DualEncoder()
        let service = MLSearchService(
            descriptor: descriptor,
            store: InMemoryMLIndexStore(),
            assetEmbedder: encoder,
            textEncoder: encoder,
            scorer: ReferenceDotProductScorer(),
            releaseInferenceResources: { releases.increment() }
        )

        _ = await service.indexQuantum(
            [uid("tree"), uid("water")],
            libraryGeneration: 1,
            maximumAssets: 1,
            shouldContinue: { true },
            observer: MLIndexPassObserver()
        )
        #expect(releases.value == 0)

        await service.releaseMemory()
        #expect(releases.value == 1)
    }

    @Test func drainedQuantumReleasesInferenceResourcesBeforeIdle() async {
        let releases = ReleaseCounter()
        let encoder = DualEncoder()
        let service = MLSearchService(
            descriptor: descriptor,
            store: InMemoryMLIndexStore(),
            assetEmbedder: encoder,
            textEncoder: encoder,
            scorer: ReferenceDotProductScorer(),
            releaseInferenceResources: { releases.increment() }
        )

        let outcome = await service.indexQuantum(
            [uid("tree")],
            libraryGeneration: 1,
            maximumAssets: 1,
            shouldContinue: { true },
            observer: MLIndexPassObserver()
        )

        #expect(outcome.ranToCompletion)
        #expect(releases.value == 1)
    }
}

private final class ReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
