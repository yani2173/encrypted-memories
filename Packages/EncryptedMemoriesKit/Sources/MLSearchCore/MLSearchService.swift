import PhotosCore

/// Universal semantic-search entry point shared by every host platform.
///
/// The service binds one model epoch to indexing, coverage and querying so platform UIs cannot
/// accidentally diverge in descriptors, retry behavior or ranking semantics.
public actor MLSearchService {
    public let descriptor: MLModelDescriptor

    private let runner: MLIndexRunner
    private let searchEngine: MLSemanticSearchEngine
    private let releaseInferenceResources: (@Sendable () async -> Void)?

    public init(
        descriptor: MLModelDescriptor,
        store: any MLIndexStore,
        assetEmbedder: any MLAssetEmbedder,
        textEncoder: any MLTextQueryEncoder,
        scorer: any MLVectorScorer,
        relevancePolicy: MLSemanticRelevancePolicy = .unfiltered,
        runnerConfiguration: MLIndexRunner.Configuration = .init(),
        shouldContinue: @escaping @Sendable () -> Bool = { true },
        releaseInferenceResources: (@Sendable () async -> Void)? = nil
    ) {
        self.descriptor = descriptor
        self.runner = MLIndexRunner(
            store: store,
            embedder: assetEmbedder,
            configuration: runnerConfiguration,
            shouldContinue: shouldContinue
        )
        self.searchEngine = MLSemanticSearchEngine(
            store: store,
            encoder: textEncoder,
            scorer: scorer,
            relevancePolicy: relevancePolicy
        )
        self.releaseInferenceResources = releaseInferenceResources
    }

    public func index(
        _ assets: [PhotoUID],
        observer: MLIndexPassObserver = MLIndexPassObserver()
    ) async -> MLIndexPassOutcome {
        let outcome = await runIndexPass(
            assets,
            maximumAssets: nil,
            observer: observer
        )
        await releaseInferenceResources?()
        return outcome
    }

    public func indexQuantum(
        _ assets: [PhotoUID],
        libraryGeneration: UInt64,
        maximumAssets: Int,
        shouldContinue: @escaping @Sendable () -> Bool,
        observer: MLIndexPassObserver
    ) async -> MLIndexPassOutcome {
        let outcome = await runIndexPass(
            assets,
            maximumAssets: maximumAssets,
            libraryGeneration: libraryGeneration,
            passShouldContinue: shouldContinue,
            observer: observer
        )
        await releaseAfterDrainedQuantum(outcome)
        return outcome
    }

    private func runIndexPass(
        _ assets: [PhotoUID],
        maximumAssets: Int?,
        libraryGeneration: UInt64? = nil,
        passShouldContinue: @escaping @Sendable () -> Bool = { true },
        observer: MLIndexPassObserver
    ) async -> MLIndexPassOutcome {
        let outcome = await runner.runPass(
            allAssets: assets,
            descriptor: descriptor,
            maximumAssets: maximumAssets,
            libraryGeneration: libraryGeneration,
            passShouldContinue: passShouldContinue,
            observer: observer
        )
        return outcome
    }

    /// Retain the image model only across adjacent bounded quanta. A drained plan either completed indexing
    /// or is about to wait for retry input, so keeping the model resident would consume memory while idle.
    private func releaseAfterDrainedQuantum(_ outcome: MLIndexPassOutcome) async {
        guard outcome.ranToCompletion else { return }
        await releaseInferenceResources?()
    }

    public func search(_ text: String, limit: Int = 50) async throws -> MLSearchResults {
        try await searchEngine.search(
            MLSearchQuery(descriptor: descriptor, queryText: text, limit: limit)
        )
    }

    public func search(
        _ text: String, limit: Int, shouldContinue: @escaping @Sendable () -> Bool
    ) async throws -> MLSearchResults {
        try await searchEngine.search(
            MLSearchQuery(descriptor: descriptor, queryText: text, limit: limit),
            shouldContinue: shouldContinue
        )
    }

    public func searchBatch(
        _ texts: [String], limit: Int, shouldContinue: @escaping @Sendable () -> Bool
    ) async throws -> MLSearchBatchResults {
        try await searchEngine.searchBatch(
            texts.map { MLSearchQuery(descriptor: descriptor, queryText: $0, limit: limit) },
            shouldContinue: shouldContinue
        )
    }

    public func coverage(for assets: [PhotoUID]) async throws -> MLIndexCoverage {
        try await searchEngine.coverage(for: descriptor, allAssets: assets)
    }

    public func permanentlyUnavailableAssetUIDs(_ assets: [PhotoUID]) async throws -> Set<PhotoUID> {
        try await searchEngine.permanentlyUnavailableAssetUIDs(for: descriptor, allAssets: assets)
    }

    public func releaseMemory() async {
        await searchEngine.purgePromptEmbeddings()
        await releaseInferenceResources?()
    }
}
