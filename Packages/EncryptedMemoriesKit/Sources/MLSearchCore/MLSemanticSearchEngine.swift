import Foundation
import PhotosCore

public protocol MLTextQueryEncoder: Sendable {
    func encode(text: String, descriptor: MLModelDescriptor) async throws -> ContiguousArray<Float32>
}

public enum MLSemanticSearchError: Error, Equatable {
    case incompatibleBatch
    case emptyQuery
    case invalidQueryEmbedding
    case queryDimensionMismatch(expected: Int, actual: Int)
}

/// Shared semantic query path for every host platform.
///
/// The engine owns query normalization, bounded index streaming and deterministic ranking. CoreML
/// model execution and Accelerate arithmetic remain injected adapters, so iOS, iPadOS and macOS
/// cannot diverge in search semantics.
public actor MLSemanticSearchEngine {
    private let store: any MLIndexStore
    private let encoder: any MLTextQueryEncoder
    private let scorer: any MLVectorScorer
    private let relevancePolicy: MLSemanticRelevancePolicy
    /// A 512-dimensional Float32 query block uses about 4 MiB at this row limit.
    /// The bound applies to every library size; top-k memory still follows the requested limit.
    public static let defaultQueryBlockRowLimit = 2_048
    private let queryBlockRowLimit: Int
    private struct PromptKey: Hashable {
        let descriptor: MLModelDescriptor
        let text: String
    }
    private var promptEmbeddings: [PromptKey: ContiguousArray<Float32>] = [:]

    public init(
        store: any MLIndexStore,
        encoder: any MLTextQueryEncoder,
        scorer: any MLVectorScorer,
        relevancePolicy: MLSemanticRelevancePolicy = .unfiltered,
        queryBlockRowLimit: Int = MLSemanticSearchEngine.defaultQueryBlockRowLimit
    ) {
        self.store = store
        self.encoder = encoder
        self.scorer = scorer
        self.relevancePolicy = relevancePolicy
        self.queryBlockRowLimit = max(1, queryBlockRowLimit)
    }

    public func search(
        _ query: MLSearchQuery,
        shouldContinue: @escaping @Sendable () -> Bool = { true }
    ) async throws -> MLSearchResults {
        func checkContinuation() throws {
            try Task.checkCancellation()
            guard shouldContinue() else { throw CancellationError() }
        }
        try checkContinuation()
        let text = query.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MLSemanticSearchError.emptyQuery }

        let normalized = try await normalizedQueryVector(
            text: text, descriptor: query.descriptor, checkContinuation: checkContinuation)

        let startedAt = ContinuousClock.now
        var rankedResults: [MLSearchResult] = []
        if query.limit > 0 {
            try store.forEachVectorBlock(
                for: query.descriptor,
                maximumRows: queryBlockRowLimit
            ) { block in
                try checkContinuation()
                let blockResults = scorer.rank(
                    block: block,
                    query: normalized,
                    limit: query.limit,
                    queryText: text
                ).results
                rankedResults = Self.mergeTopResults(
                    rankedResults,
                    blockResults,
                    limit: query.limit
                )
            }
        }
        try checkContinuation()
        let duration = ContinuousClock.now - startedAt
        return MLSearchResults(
            descriptor: query.descriptor,
            queryText: text,
            results: relevancePolicy.relevantResults(from: rankedResults),
            durationMs: Self.milliseconds(duration)
        )
    }

    /// Suggestion prompts share one bounded index read. Scoring and relevance remain identical to single queries.
    /// Cached prompt vectors are small, model-scoped, bounded, and released with other derived resources.
    public func searchBatch(
        _ queries: [MLSearchQuery],
        shouldContinue: @escaping @Sendable () -> Bool = { true }
    ) async throws -> MLSearchBatchResults {
        guard let first = queries.first else { return MLSearchBatchResults(results: [], scannedUIDs: []) }
        guard queries.count <= 40, queries.allSatisfy({ $0.descriptor == first.descriptor }) else {
            throw MLSemanticSearchError.incompatibleBatch
        }
        func checkContinuation() throws {
            try Task.checkCancellation()
            guard shouldContinue() else { throw CancellationError() }
        }
        let startedAt = ContinuousClock.now
        var texts: [String] = []
        var vectors: [ContiguousArray<Float32>] = []
        for query in queries {
            try checkContinuation()
            let text = query.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw MLSemanticSearchError.emptyQuery }
            let key = PromptKey(descriptor: query.descriptor, text: text)
            let vector: ContiguousArray<Float32>
            if let cached = promptEmbeddings[key] {
                vector = cached
            } else {
                vector = try await normalizedQueryVector(
                    text: text, descriptor: query.descriptor, checkContinuation: checkContinuation)
                if promptEmbeddings.count >= 40 { promptEmbeddings.removeAll(keepingCapacity: true) }
                promptEmbeddings[key] = vector
            }
            texts.append(text)
            vectors.append(vector)
        }
        var ranked = Array(repeating: [MLSearchResult](), count: queries.count)
        var scannedUIDs = MLScannedUIDMembership()
        if queries.contains(where: { $0.limit > 0 }) {
            try store.forEachVectorBlock(
                for: first.descriptor, maximumRows: min(queryBlockRowLimit, 256)
            ) { block in
                for index in queries.indices where queries[index].limit > 0 {
                    try checkContinuation()
                    let results = scorer.rank(
                        block: block, query: vectors[index], limit: queries[index].limit, queryText: texts[index]
                    ).results
                    ranked[index] = Self.mergeTopResults(ranked[index], results, limit: queries[index].limit)
                }
                if queries.allSatisfy({ $0.limit > 0 }) {
                    scannedUIDs.formUnion(block.uids)
                }
            }
        }
        try checkContinuation()
        let duration = ContinuousClock.now - startedAt
        let durationMs = Self.milliseconds(duration)
        let results = queries.indices.map { index in
            MLSearchResults(
                descriptor: first.descriptor, queryText: texts[index],
                results: relevancePolicy.relevantResults(from: ranked[index]), durationMs: durationMs
            )
        }
        return MLSearchBatchResults(results: results, scannedUIDs: scannedUIDs)
    }

    public func coverage(for descriptor: MLModelDescriptor, allAssets: [PhotoUID]) throws -> MLIndexCoverage {
        try store.coverage(for: descriptor, allAssets: allAssets)
    }

    public func permanentlyUnavailableAssetUIDs(
        for descriptor: MLModelDescriptor,
        allAssets: [PhotoUID]
    ) throws -> Set<PhotoUID> {
        let assets = Array(Set(allAssets))
        let indexed = try store.indexedUIDs(for: descriptor, from: assets)
        return Set(
            try store.failureRecords(for: descriptor, from: assets).values.compactMap { failure in
                failure.kind == .permanent && !indexed.contains(failure.uid) ? failure.uid : nil
            })
    }

    /// Index vectors are streamed, so only the prompt-embedding cache is held. Lifecycle callers also
    /// release the inference model through the adapter.
    public func purgePromptEmbeddings() {
        promptEmbeddings.removeAll()
    }

    private func normalizedQueryVector(
        text: String,
        descriptor: MLModelDescriptor,
        checkContinuation: () throws -> Void
    ) async throws -> ContiguousArray<Float32> {
        let raw = try await encoder.encode(text: text, descriptor: descriptor)
        try checkContinuation()
        guard raw.count == descriptor.embeddingDimension else {
            throw MLSemanticSearchError.queryDimensionMismatch(
                expected: descriptor.embeddingDimension, actual: raw.count
            )
        }
        guard let normalized = MLVectorNormalization.normalized(raw) else {
            throw MLSemanticSearchError.invalidQueryEmbedding
        }
        return normalized
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private static func mergeTopResults(
        _ existing: [MLSearchResult],
        _ incoming: [MLSearchResult],
        limit: Int
    ) -> [MLSearchResult] {
        guard !incoming.isEmpty else { return existing }
        var merged: [MLSearchResult] = []
        merged.reserveCapacity(min(limit, existing.count + incoming.count))
        var existingIndex = 0
        var incomingIndex = 0

        while merged.count < limit,
            existingIndex < existing.count || incomingIndex < incoming.count
        {
            if incomingIndex == incoming.count {
                merged.append(existing[existingIndex])
                existingIndex += 1
            } else if existingIndex == existing.count {
                merged.append(incoming[incomingIndex])
                incomingIndex += 1
            } else if existing[existingIndex].score >= incoming[incomingIndex].score {
                // Blocks arrive in store order, so retaining the existing row first preserves
                // the scorer's deterministic ascending-row tie break across block boundaries.
                merged.append(existing[existingIndex])
                existingIndex += 1
            } else {
                merged.append(incoming[incomingIndex])
                incomingIndex += 1
            }
        }
        return merged
    }
}
