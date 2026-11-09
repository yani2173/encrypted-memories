import Foundation
import PhotosCore

/// Stable, locale-independent text normalization for private local indexes. Display text remains
/// in the encrypted artifact payload; only these normalized tokens enter keyed lookup postings.
public enum MLTextIndexNormalizer {
    public static func tokens(in text: String, limit: Int = 512) -> [String] {
        guard limit > 0 else { return [] }
        let folded = text
            .precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .replacingOccurrences(of: "ß", with: "ss")

        var result: [String] = []
        var seen: Set<String> = []
        var current = String.UnicodeScalarView()

        func flush() {
            guard !current.isEmpty else { return }
            let token = String(current.prefix(128))
            current.removeAll(keepingCapacity: true)
            if !token.isEmpty, seen.insert(token).inserted {
                result.append(token)
            }
        }

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(scalar)
            } else {
                flush()
                if result.count >= limit { return result }
            }
        }
        flush()
        return Array(result.prefix(limit))
    }

    public static func tokens<S: Sequence>(in values: S, limit: Int = 512) -> [String]
    where S.Element == String {
        guard limit > 0 else { return [] }
        var result: [String] = []
        var seen: Set<String> = []
        for value in values {
            for token in tokens(in: value, limit: limit) where seen.insert(token).inserted {
                result.append(token)
                if result.count == limit { return result }
            }
        }
        return result
    }
}

public struct MLNativeSearchConfiguration: Sendable, Equatable {
    public static let pipelineID = MLPipelineID.nativeSearch
    /// Execution-schema version. Artifact payload changes use each stage's independent
    /// `schemaEpoch`; adding a native stage must not invalidate existing OCR/document/barcode work.
    public static let schemaVersion = 1
    public static let preprocessingRevision = "cached-thumbnail-orientation-v1"

    public let executionKey: MLPipelineExecutionKey
    public let backendsByArtifact: [MLDerivedArtifactIdentity: MLSearchBackend]

    public init(
        accountIdentifier: String,
        capabilitySnapshot: MLNativeAnalysisCapabilitySnapshot
    ) throws {
        var mapping: [MLDerivedArtifactIdentity: MLSearchBackend] = [:]
        var artifacts: Set<MLDerivedArtifactIdentity> = []
        for stage in Self.analysisStages {
            let kind = stage.kind
            guard let capability = capabilitySnapshot.capability(for: kind),
                capability.isAvailable,
                capability.executionMode == .indexed,
                let revision = capability.selectedRevision
            else { continue }
            let artifact = try MLDerivedArtifactIdentity(
                pipelineID: Self.pipelineID,
                stageID: MLStageID(rawValue: stage.stageID),
                producer: .native(
                    providerIdentifier: capabilitySnapshot.providerIdentifier,
                    kind: kind,
                    requestRevision: revision
                ),
                preprocessingRevision: Self.preprocessingRevision(
                    capability: capability
                ),
                output: stage.output,
                schemaEpoch: stage.schemaEpoch
            )
            artifacts.insert(artifact)
            mapping[artifact] = stage.backend
        }
        guard !artifacts.isEmpty else { throw MLNativeSearchConfigurationError.noSearchableCapabilities }
        executionKey = try MLPipelineExecutionKey(
            accountIdentifier: accountIdentifier,
            pipelineID: Self.pipelineID,
            schemaVersion: Self.schemaVersion,
            artifacts: artifacts
        )
        backendsByArtifact = mapping
    }

    public var availableBackends: Set<MLSearchBackend> { Set(backendsByArtifact.values) }

    /// Vision can expand the effective languages, identifiers, animals or symbologies of an
    /// existing request revision. Those options affect executor output and therefore belong to the
    /// derived artifact identity even when the framework's request revision itself is unchanged.
    private static func preprocessingRevision(
        capability: MLNativeAnalysisCapability
    ) -> String {
        let components = [
            "vision-runtime-configuration-v1",
            capability.implementationIdentifier,
            stableList(capability.supportedLanguages),
            stableList(capability.supportedIdentifiers),
            stableList(capability.supportedAnimals),
            stableList(capability.supportedSymbologies),
        ]
        return ([preprocessingRevision] + components)
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }

    private static func stableList(_ values: [String]) -> String {
        Array(Set(values)).sorted().map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    public func key(for scope: MLSearchScope) -> MLPipelineExecutionKey? {
        let selectedBackends: Set<MLSearchBackend>
        switch scope {
        case .all: selectedBackends = availableBackends
        case .text: selectedBackends = [.recognizedText, .documentText]
        case .documents: selectedBackends = [.documentText]
        case .barcodes: selectedBackends = [.barcodePayload]
        case .semantic, .similar: return nil
        }
        let artifacts = Set(backendsByArtifact.compactMap { selectedBackends.contains($0.value) ? $0.key : nil })
        guard !artifacts.isEmpty else { return nil }
        return try? MLPipelineExecutionKey(
            accountIdentifier: executionKey.accountIdentifier,
            pipelineID: executionKey.pipelineID,
            schemaVersion: executionKey.schemaVersion,
            artifacts: artifacts
        )
    }

    private struct AnalysisStage: Sendable {
        let kind: MLNativeAnalysisKind
        let output: MLAnalysisOutputDescriptor
        let backend: MLSearchBackend
        let stageID: String
        let schemaEpoch: Int

        init(
            kind: MLNativeAnalysisKind,
            output: MLAnalysisOutputDescriptor,
            backend: MLSearchBackend,
            stageID: String,
            schemaEpoch: Int = 1
        ) {
            self.kind = kind
            self.output = output
            self.backend = backend
            self.stageID = stageID
            self.schemaEpoch = schemaEpoch
        }
    }

    /// Search scheduling contains only stages with a serving backend. The capability inventory
    /// is broader so on-demand and qualification evidence can still name every Vision stage.
    private static let analysisStages: [AnalysisStage] = [
        .init(kind: .textRecognition, output: .recognizedText, backend: .recognizedText, stageID: "recognized-text"),
        .init(
            kind: .documentRecognition, output: .structuredDocument, backend: .documentText,
            stageID: "structured-document"),
        .init(kind: .barcodeDetection, output: .barcodePayload, backend: .barcodePayload, stageID: "barcode-payload"),
    ]
}

public enum MLNativeSearchConfigurationError: Error, Equatable {
    case noSearchableCapabilities
}

public protocol MLNativeSearchServing: Sendable {
    func availableBackends() async -> Set<MLSearchBackend>
    func maximumConcurrentAssets() async -> Int
    func hasIndexedTextEntries() async -> Bool
    func indexQuantum(
        assets: [MLPipelineAssetRevision],
        libraryGeneration: UInt64,
        allowsDestructiveReconciliation: Bool,
        destructiveReconciliationIsAuthorized: @escaping @Sendable () async -> Bool,
        maximumAssets: Int,
        maximumConcurrentAssets: Int,
        shouldContinue: @escaping @Sendable () -> Bool,
        observer: MLDerivedPipelineObserver
    ) async -> MLDerivedPipelinePassOutcome
    func search(_ text: String, scope: MLSearchScope, limit: Int) async -> [PhotoUID]
    func progress() async -> MLDerivedPipelineProgress
    func unavailableAssetUIDs() async throws -> Set<PhotoUID>
    func purge() async
    func shutdown() async
}

public extension MLNativeSearchServing {
    func maximumConcurrentAssets() async -> Int { 1 }

    /// Conservative default: a conformer that does not report its text index is treated as having
    /// none, so the OCR scope stays hidden instead of offering a scope that cannot answer.
    func hasIndexedTextEntries() async -> Bool { false }

    func unavailableAssetUIDs() async -> Set<PhotoUID> { [] }
}

/// Core-owned native-analysis runtime shared by every Apple host. The adapter supplies one executor;
/// queueing, retry, encrypted persistence, token lookup and search scope remain platform-neutral.
public actor MLNativeSearchRuntime: MLNativeSearchServing {
    private let configuration: MLNativeSearchConfiguration
    private let store: any MLDerivedPipelineStore
    private let executor: any MLDerivedPipelineExecutor
    private let runnerConfiguration: MLIndexRunner.Configuration
    private var preparedLibraryGeneration: UInt64?
    private var lastKnownProgress = MLDerivedPipelineProgress(
        total: 0,
        completed: 0,
        skipped: 0,
        permanentFailure: 0,
        retryPending: 0,
        generation: 0
    )

    public init(
        configuration: MLNativeSearchConfiguration,
        store: any MLDerivedPipelineStore,
        executor: any MLDerivedPipelineExecutor,
        runnerConfiguration: MLIndexRunner.Configuration = .init()
    ) {
        self.configuration = configuration
        self.store = store
        self.executor = executor
        self.runnerConfiguration = runnerConfiguration
    }

    public func availableBackends() -> Set<MLSearchBackend> {
        configuration.availableBackends
    }

    public func maximumConcurrentAssets() async -> Int {
        runnerConfiguration.maximumConcurrentDerivedAssets
    }

    public func index(
        assets: [MLPipelineAssetRevision],
        shouldContinue: @escaping @Sendable () -> Bool,
        observer: MLDerivedPipelineObserver = MLDerivedPipelineObserver()
    ) async -> MLDerivedPipelinePassOutcome {
        await index(
            assets: assets,
            libraryGeneration: nil,
            maximumAssets: nil,
            shouldContinue: shouldContinue,
            observer: observer
        )
    }

    public func indexQuantum(
        assets: [MLPipelineAssetRevision],
        libraryGeneration: UInt64,
        allowsDestructiveReconciliation: Bool,
        destructiveReconciliationIsAuthorized: @escaping @Sendable () async -> Bool,
        maximumAssets: Int,
        maximumConcurrentAssets: Int,
        shouldContinue: @escaping @Sendable () -> Bool,
        observer: MLDerivedPipelineObserver
    ) async -> MLDerivedPipelinePassOutcome {
        await index(
            assets: assets,
            libraryGeneration: libraryGeneration,
            allowsDestructiveReconciliation: allowsDestructiveReconciliation,
            destructiveReconciliationIsAuthorized: destructiveReconciliationIsAuthorized,
            maximumAssets: maximumAssets,
            maximumConcurrentAssets: maximumConcurrentAssets,
            shouldContinue: shouldContinue,
            observer: observer
        )
    }

    private func index(
        assets: [MLPipelineAssetRevision],
        libraryGeneration: UInt64?,
        allowsDestructiveReconciliation: Bool = true,
        destructiveReconciliationIsAuthorized: @escaping @Sendable () async -> Bool = { true },
        maximumAssets: Int?,
        maximumConcurrentAssets: Int? = nil,
        shouldContinue: @escaping @Sendable () -> Bool,
        observer: MLDerivedPipelineObserver
    ) async -> MLDerivedPipelinePassOutcome {
        if libraryGeneration == nil || preparedLibraryGeneration != libraryGeneration {
            guard store.enqueue(assets, for: configuration.executionKey) else {
                return MLDerivedPipelinePassOutcome(
                    reason: .storageFailure,
                    progress: readProgressOrLast()
                )
            }
            preparedLibraryGeneration = libraryGeneration
        }
        var passConfiguration = runnerConfiguration
        if let maximumConcurrentAssets {
            passConfiguration.maximumConcurrentDerivedAssets = min(
                runnerConfiguration.maximumConcurrentDerivedAssets,
                max(1, maximumConcurrentAssets)
            )
        }
        let outcome = await MLIndexRunner.runDerivedPass(
            key: configuration.executionKey,
            store: store,
            executor: executor,
            configuration: passConfiguration,
            maximumAnalysisPlans: maximumAssets,
            shouldContinue: shouldContinue,
            observer: observer
        )
        // The runner's initial-read fallback carries the storage-failure reason but no trustworthy
        // counts. Keep the last successful snapshot until SQLite can be read again.
        if outcome.reason != .storageFailure {
            lastKnownProgress = outcome.progress
        }
        guard allowsDestructiveReconciliation,
            outcome.reason == .drained,
            outcome.progress.isComplete
        else { return outcome }
        guard await destructiveReconciliationIsAuthorized() else { return outcome }
        guard
            store.reconcile(
                liveUIDs: Set(assets.map(\.uid)),
                for: configuration.executionKey
            )
        else {
            return MLDerivedPipelinePassOutcome(
                reason: .storageFailure,
                progress: readProgressOrLast()
            )
        }
        guard let progress = try? store.progress(for: configuration.executionKey) else {
            return MLDerivedPipelinePassOutcome(
                reason: .storageFailure,
                progress: lastKnownProgress
            )
        }
        lastKnownProgress = progress
        return MLDerivedPipelinePassOutcome(
            reason: .drained,
            progress: progress
        )
    }

    public func search(_ text: String, scope: MLSearchScope, limit: Int) -> [PhotoUID] {
        guard let key = configuration.key(for: scope) else { return [] }
        let tokens = MLTextIndexNormalizer.tokens(in: text, limit: 16)
        return store.search(normalizedTokens: tokens, in: key, limit: limit).map(\.uid)
    }

    /// The OCR scope is offered only when the current library's text index holds at least one
    /// committed entry. A missing text configuration or an unreadable store both report `false`.
    public func hasIndexedTextEntries() -> Bool {
        guard let key = configuration.key(for: .text) else { return false }
        return store.hasIndexedEntries(for: key)
    }

    public func progress() -> MLDerivedPipelineProgress {
        readProgressOrLast()
    }

    public func unavailableAssetUIDs() throws -> Set<PhotoUID> {
        try store.unavailableAssetUIDs(for: configuration.executionKey)
    }

    public func purge() {
        store.purge(
            pipelineID: configuration.executionKey.pipelineID,
            accountIdentifier: configuration.executionKey.accountIdentifier
        )
    }

    public func shutdown() {
        store.close()
    }

    private func readProgressOrLast() -> MLDerivedPipelineProgress {
        guard let progress = try? store.progress(for: configuration.executionKey) else {
            return lastKnownProgress
        }
        lastKnownProgress = progress
        return progress
    }
}

/// Deterministic fusion of independent rank spaces. It never adds semantic similarities to text
/// scores; instead it interleaves ranked lists and removes duplicates while preserving source order.
public enum MLSearchRankFusion {
    public static func interleaved(_ rankedSources: [[PhotoUID]], limit: Int) -> [PhotoUID] {
        guard limit > 0 else { return [] }
        var result: [PhotoUID] = []
        var seen: Set<PhotoUID> = []
        var index = 0
        while result.count < limit {
            var appended = false
            for source in rankedSources where index < source.count {
                let uid = source[index]
                if seen.insert(uid).inserted {
                    result.append(uid)
                    if result.count == limit { return result }
                }
                appended = true
            }
            guard appended else { break }
            index += 1
        }
        return result
    }
}
