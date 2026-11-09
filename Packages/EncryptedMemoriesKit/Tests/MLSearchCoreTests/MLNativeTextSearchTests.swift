import Foundation
import PhotosCore
import Testing

@testable import MLSearchCore

@Suite struct MLNativeTextSearchTests {
    @Test func normalizationIsDeterministicForGermanAndEnglishText() {
        #expect(
            MLTextIndexNormalizer.tokens(in: "Grüße, STRASSE! Café １２３") == [
                "grusse", "strasse", "cafe", "123",
            ])
        #expect(MLTextIndexNormalizer.tokens(in: ["Hello hello", "WÖRLD"]) == ["hello", "world"])
    }

    @Test func capabilityConfigurationKeepsIndependentScopes() throws {
        let configuration = try MLNativeSearchConfiguration(
            accountIdentifier: "account",
            capabilitySnapshot: capabilitySnapshot(kinds: [.textRecognition, .barcodeDetection])
        )
        #expect(configuration.availableBackends == [.recognizedText, .barcodePayload])
        #expect(configuration.key(for: .text)?.artifacts.count == 1)
        #expect(configuration.key(for: .barcodes)?.artifacts.count == 1)
        #expect(configuration.key(for: .documents) == nil)
        #expect(configuration.key(for: .semantic) == nil)
    }

    @Test func defaultConfigurationSchedulesOnlyStagesWithSearchBackends() throws {
        let configuration = try MLNativeSearchConfiguration(
            accountIdentifier: "account",
            capabilitySnapshot: capabilitySnapshot(kinds: Set(MLNativeAnalysisKind.allCases))
        )

        #expect(configuration.executionKey.artifacts.count == 3)
        #expect(
            configuration.availableBackends == [
                .recognizedText,
                .documentText,
                .barcodePayload,
            ])
    }

    @Test func structuredDocumentsActivateOnlyWhenTheRuntimeSupportsThem() throws {
        let configuration = try MLNativeSearchConfiguration(
            accountIdentifier: "account",
            capabilitySnapshot: capabilitySnapshot(kinds: [
                .textRecognition,
                .documentRecognition,
                .barcodeDetection,
            ])
        )
        #expect(
            configuration.availableBackends == [
                .recognizedText,
                .documentText,
                .barcodePayload,
            ])
        #expect(configuration.key(for: .text)?.artifacts.count == 2)
        #expect(configuration.key(for: .documents)?.artifacts.count == 1)
        #expect(configuration.executionKey.artifacts.count == 3)
    }

    @Test func activeConfigurationExcludesAvailableNonIndexedCapabilities() throws {
        let snapshot = MLNativeAnalysisCapabilitySnapshot(
            providerIdentifier: "apple.vision",
            sdkIdentifier: "test",
            capabilities: [
                capability(.textRecognition, mode: .indexed),
                capability(.humanDetection, mode: .onDemand),
                capability(.imageClassification, mode: .temporalOrPairwise),
                capability(.animalRecognition, mode: .unsupported),
            ]
        )

        let configuration = try MLNativeSearchConfiguration(
            accountIdentifier: "account",
            capabilitySnapshot: snapshot
        )

        #expect(configuration.executionKey.artifacts.count == 1)
        #expect(
            configuration.executionKey.artifacts.first?.producer
                == .native(
                    providerIdentifier: "apple.vision",
                    kind: .textRecognition,
                    requestRevision: "revision1"
                ))
    }

    @Test func runtimeVocabularyChangesOnlyTheAffectedArtifactIdentity() throws {
        func snapshot(languages: [String], symbologies: [String]) -> MLNativeAnalysisCapabilitySnapshot {
            MLNativeAnalysisCapabilitySnapshot(
                providerIdentifier: "apple.vision",
                sdkIdentifier: "test",
                capabilities: [
                    MLNativeAnalysisCapability(
                        kind: .textRecognition,
                        implementationIdentifier: "RecognizeTextRequest",
                        availability: .available,
                        selectedRevision: "revision3",
                        supportedRevisions: ["revision3"],
                        supportedLanguages: languages
                    ),
                    MLNativeAnalysisCapability(
                        kind: .barcodeDetection,
                        implementationIdentifier: "DetectBarcodesRequest",
                        availability: .available,
                        selectedRevision: "revision4",
                        supportedRevisions: ["revision4"],
                        supportedSymbologies: symbologies
                    ),
                ]
            )
        }
        func artifact(
            _ kind: MLNativeAnalysisKind,
            in configuration: MLNativeSearchConfiguration
        ) -> MLDerivedArtifactIdentity? {
            configuration.executionKey.artifacts.first { artifact in
                guard case .native(_, let candidate, _) = artifact.producer else { return false }
                return candidate == kind
            }
        }

        let baseline = try MLNativeSearchConfiguration(
            accountIdentifier: "account",
            capabilitySnapshot: snapshot(languages: ["en-US", "de-DE"], symbologies: ["qr"])
        )
        let reordered = try MLNativeSearchConfiguration(
            accountIdentifier: "account",
            capabilitySnapshot: snapshot(languages: ["de-DE", "en-US"], symbologies: ["qr"])
        )
        let expanded = try MLNativeSearchConfiguration(
            accountIdentifier: "account",
            capabilitySnapshot: snapshot(languages: ["de-DE", "en-US", "fr-FR"], symbologies: ["qr"])
        )

        #expect(artifact(.textRecognition, in: baseline) == artifact(.textRecognition, in: reordered))
        #expect(artifact(.textRecognition, in: baseline) != artifact(.textRecognition, in: expanded))
        #expect(artifact(.barcodeDetection, in: baseline) == artifact(.barcodeDetection, in: expanded))
    }

    @Test func nativeRuntimeIndexesAndSearchesWithoutMixingScopes() async throws {
        let configuration = try MLNativeSearchConfiguration(
            accountIdentifier: "account",
            capabilitySnapshot: capabilitySnapshot(kinds: [.textRecognition, .barcodeDetection])
        )
        let runtime = MLNativeSearchRuntime(
            configuration: configuration,
            store: InMemoryMLDerivedPipelineStore(),
            executor: NativeTextTestExecutor()
        )
        let asset = try MLPipelineAssetRevision(
            uid: PhotoUID(volumeID: "volume", nodeID: "photo"),
            sourceRevision: "photo"
        )
        let outcome = await runtime.index(assets: [asset], shouldContinue: { true })
        #expect(outcome.reason == .drained)
        #expect(await runtime.search("Grüße", scope: .text, limit: 10) == [asset.uid])
        #expect(await runtime.search("qr-42", scope: .barcodes, limit: 10) == [asset.uid])
        #expect(await runtime.search("qr-42", scope: .text, limit: 10).isEmpty)
    }

    @Test func nativeRuntimeIndexesStructuredDocumentsWithoutASemanticModel() async throws {
        let configuration = try MLNativeSearchConfiguration(
            accountIdentifier: "account",
            capabilitySnapshot: capabilitySnapshot(kinds: [
                .textRecognition,
                .documentRecognition,
                .barcodeDetection,
            ])
        )
        let runtime = MLNativeSearchRuntime(
            configuration: configuration,
            store: InMemoryMLDerivedPipelineStore(),
            executor: NativeTextTestExecutor()
        )
        let asset = try MLPipelineAssetRevision(uid: uid("document"), sourceRevision: "document-v1")

        #expect(await runtime.index(assets: [asset], shouldContinue: { true }).reason == .drained)
        #expect(await runtime.search("rechnung", scope: .documents, limit: 10) == [asset.uid])
        #expect(await runtime.search("rechnung", scope: .text, limit: 10) == [asset.uid])
        #expect(await runtime.search("rechnung", scope: .barcodes, limit: 10).isEmpty)
        #expect(await runtime.progress().total == 3)
    }

    @Test func completedPassRemovesDeletedAssetsFromEveryNativePosting() async throws {
        let configuration = try MLNativeSearchConfiguration(
            accountIdentifier: "account",
            capabilitySnapshot: capabilitySnapshot(kinds: [.textRecognition, .barcodeDetection])
        )
        let runtime = MLNativeSearchRuntime(
            configuration: configuration,
            store: InMemoryMLDerivedPipelineStore(),
            executor: NativeTextTestExecutor()
        )
        let retained = try MLPipelineAssetRevision(uid: uid("retained"), sourceRevision: "retained")
        let deleted = try MLPipelineAssetRevision(uid: uid("deleted"), sourceRevision: "deleted")

        #expect(await runtime.index(assets: [retained, deleted], shouldContinue: { true }).reason == .drained)
        #expect(Set(await runtime.search("grusse", scope: .text, limit: 10)) == [retained.uid, deleted.uid])

        #expect(await runtime.index(assets: [retained], shouldContinue: { true }).reason == .drained)
        #expect(await runtime.search("grusse", scope: .text, limit: 10) == [retained.uid])
        #expect(await runtime.progress().total == 2)
    }

    @Test func completedPassRevalidatesAuthorityBeforeRemovingStoredAssets() async throws {
        let configuration = try MLNativeSearchConfiguration(
            accountIdentifier: "account",
            capabilitySnapshot: capabilitySnapshot(kinds: [.textRecognition])
        )
        let runtime = MLNativeSearchRuntime(
            configuration: configuration,
            store: InMemoryMLDerivedPipelineStore(),
            executor: NativeTextTestExecutor()
        )
        let retained = try MLPipelineAssetRevision(uid: uid("retained"), sourceRevision: "retained")
        let removed = try MLPipelineAssetRevision(uid: uid("removed"), sourceRevision: "removed")
        _ = await runtime.index(assets: [retained, removed], shouldContinue: { true })

        let fenced = await runtime.indexQuantum(
            assets: [retained],
            libraryGeneration: 2,
            allowsDestructiveReconciliation: true,
            destructiveReconciliationIsAuthorized: { false },
            maximumAssets: 8,
            maximumConcurrentAssets: 1,
            shouldContinue: { true },
            observer: MLDerivedPipelineObserver()
        )
        #expect(fenced.reason == .drained)
        #expect(Set(await runtime.search("grusse", scope: .text, limit: 10)) == [retained.uid, removed.uid])

        let authoritative = await runtime.indexQuantum(
            assets: [retained],
            libraryGeneration: 3,
            allowsDestructiveReconciliation: true,
            destructiveReconciliationIsAuthorized: { true },
            maximumAssets: 8,
            maximumConcurrentAssets: 1,
            shouldContinue: { true },
            observer: MLDerivedPipelineObserver()
        )
        #expect(authoritative.reason == .drained)
        #expect(await runtime.search("grusse", scope: .text, limit: 10) == [retained.uid])
    }

    @Test func completedPassWithoutDestructiveAllowanceKeepsStoredAssets() async throws {
        let configuration = try MLNativeSearchConfiguration(
            accountIdentifier: "account",
            capabilitySnapshot: capabilitySnapshot(kinds: [.textRecognition])
        )
        let runtime = MLNativeSearchRuntime(
            configuration: configuration,
            store: InMemoryMLDerivedPipelineStore(),
            executor: NativeTextTestExecutor()
        )
        let retained = try MLPipelineAssetRevision(uid: uid("retained"), sourceRevision: "retained")
        let removed = try MLPipelineAssetRevision(uid: uid("removed"), sourceRevision: "removed")
        _ = await runtime.index(assets: [retained, removed], shouldContinue: { true })

        let outcome = await runtime.indexQuantum(
            assets: [retained],
            libraryGeneration: 2,
            allowsDestructiveReconciliation: false,
            destructiveReconciliationIsAuthorized: { true },
            maximumAssets: 8,
            maximumConcurrentAssets: 1,
            shouldContinue: { true },
            observer: MLDerivedPipelineObserver()
        )
        #expect(outcome.reason == .drained)
        #expect(Set(await runtime.search("grusse", scope: .text, limit: 10)) == [retained.uid, removed.uid])
    }

    @Test func nativeRuntimeClampsConcurrencyPerQuantumWithoutCreatingUnboundedWork() async throws {
        let configuration = try MLNativeSearchConfiguration(
            accountIdentifier: "account",
            capabilitySnapshot: capabilitySnapshot(kinds: [.textRecognition])
        )
        let executor = NativeConcurrencyExecutor()
        let runtime = MLNativeSearchRuntime(
            configuration: configuration,
            store: InMemoryMLDerivedPipelineStore(),
            executor: executor,
            runnerConfiguration: .init(
                chunkSize: 32,
                maximumConcurrentDerivedAssets: 3
            )
        )
        let assets = try (0..<32).map {
            try MLPipelineAssetRevision(uid: uid("bounded-\($0)"), sourceRevision: "source-\($0)")
        }

        let first = await runtime.indexQuantum(
            assets: assets,
            libraryGeneration: 1,
            allowsDestructiveReconciliation: true,
            destructiveReconciliationIsAuthorized: { true },
            maximumAssets: 8,
            maximumConcurrentAssets: 1,
            shouldContinue: { true },
            observer: MLDerivedPipelineObserver()
        )
        #expect(first.reason == .workQuantumCompleted)
        #expect(first.progress.completed == 8)
        #expect(await executor.maximumObserved == 1)
        #expect(await executor.executionCount == 8)
        #expect(await runtime.maximumConcurrentAssets() == 3)

        await executor.resetMeasurements()
        let second = await runtime.indexQuantum(
            assets: assets,
            libraryGeneration: 1,
            allowsDestructiveReconciliation: true,
            destructiveReconciliationIsAuthorized: { true },
            maximumAssets: 9,
            maximumConcurrentAssets: 3,
            shouldContinue: { true },
            observer: MLDerivedPipelineObserver()
        )
        #expect(second.reason == .workQuantumCompleted)
        #expect(second.progress.completed == 17)
        #expect(await executor.maximumObserved == 3)
        #expect(await executor.executionCount == 9)
    }

    @Test func rankFusionNeverCombinesRawScoresAndIsStable() {
        let a = uid("a")
        let b = uid("b")
        let c = uid("c")
        #expect(MLSearchRankFusion.interleaved([[a, b], [c, a]], limit: 10) == [a, c, b])
        #expect(MLSearchRankFusion.interleaved([[a, b], [c]], limit: 2) == [a, c])
    }

    private func capabilitySnapshot(kinds: Set<MLNativeAnalysisKind>) -> MLNativeAnalysisCapabilitySnapshot {
        MLNativeAnalysisCapabilitySnapshot(
            providerIdentifier: "apple.vision",
            sdkIdentifier: "test",
            capabilities: kinds.map {
                MLNativeAnalysisCapability(
                    kind: $0,
                    implementationIdentifier: "apple.vision.\($0.rawValue)",
                    availability: .available,
                    selectedRevision: "revision1",
                    supportedRevisions: ["revision1"]
                )
            }
        )
    }

    private func capability(
        _ kind: MLNativeAnalysisKind,
        mode: MLNativeAnalysisExecutionMode
    ) -> MLNativeAnalysisCapability {
        MLNativeAnalysisCapability(
            kind: kind,
            implementationIdentifier: "apple.vision.\(kind.rawValue)",
            executionMode: mode,
            availability: .available,
            selectedRevision: "revision1",
            supportedRevisions: ["revision1"]
        )
    }

    private func uid(_ value: String) -> PhotoUID {
        PhotoUID(volumeID: "volume", nodeID: value)
    }
}

private actor NativeTextTestExecutor: MLDerivedPipelineExecutor {
    func execute(_ plan: MLAssetAnalysisPlan) async -> [MLPipelineStageResult] {
        plan.workItems.map { item in
            let text =
                switch item.artifact.output {
                case .recognizedText: "Grüße aus Wien"
                case .structuredDocument: "Rechnung aus Wien"
                default: "QR-42"
                }
            return MLPipelineStageResult(
                workItem: item,
                outcome: .completed(
                    MLDerivedPipelineOutput(
                        payload: Data(text.utf8),
                        normalizedSearchTokens: MLTextIndexNormalizer.tokens(in: text)
                    ))
            )
        }
    }
}

private actor NativeConcurrencyExecutor: MLDerivedPipelineExecutor {
    private var active = 0
    private(set) var maximumObserved = 0
    private(set) var executionCount = 0

    func execute(_ plan: MLAssetAnalysisPlan) async -> [MLPipelineStageResult] {
        active += 1
        maximumObserved = max(maximumObserved, active)
        executionCount += 1
        try? await Task.sleep(for: .milliseconds(2))
        active -= 1
        return plan.workItems.map {
            MLPipelineStageResult(
                workItem: $0,
                outcome: .completed(.init(payload: Data("ok".utf8)))
            )
        }
    }

    func resetMeasurements() {
        active = 0
        maximumObserved = 0
        executionCount = 0
    }
}
