import Foundation
import PhotosCore
import Testing

@testable import MLSearchCore

@Suite struct MLSmartSearchPresentationTests {
    private let coverage = MLIndexCoverage(total: 100, indexed: 40, permanentlyUnindexable: 2)

    @Test func waitingStateIsHonestAndKeepsDeterminateCoverage() {
        let presentation = MLSmartSearchPresentation(
            snapshot: MLSmartSearchSnapshot(
                isEnabled: true,
                selectedModelID: nil,
                phase: .waiting(coverage),
                installedModelBytes: 0,
                availableModels: [],
                isSearchAvailable: true
            ))

        #expect(presentation.indexedCount == 40)
        #expect(presentation.totalCount == 100)
        #expect(presentation.progressFraction == 0.42)
        #expect(presentation.detailText != nil)
        #expect(!presentation.isBusy)
        #expect(presentation.statusText == L10n.string("mlsearch.status_waiting"))
    }

    @Test func completedCoverageReportsUnindexableAssetsInsteadOfClaimingAllIndexed() {
        let presentation = MLSmartSearchPresentation(
            snapshot: MLSmartSearchSnapshot(
                isEnabled: true,
                selectedModelID: nil,
                phase: .ready(MLIndexCoverage(total: 10, indexed: 9, permanentlyUnindexable: 1)),
                installedModelBytes: 0,
                availableModels: [],
                isSearchAvailable: true
            ))

        #expect(presentation.indexedCount == 9)
        #expect(presentation.detailText != nil)
        #expect(
            presentation.statusText
                == L10n.string("mlsearch.status_ready \(MLSmartSearchPresentation.productName)")
        )
        #expect(presentation.presentsAsReady)
    }

    @Test func tinyResidualWorkPresentsAsReadyWithoutPretendingAssetsWereIndexed() {
        let presentation = MLSmartSearchPresentation(
            snapshot: MLSmartSearchSnapshot(
                isEnabled: true,
                selectedModelID: nil,
                phase: .waiting(MLIndexCoverage(total: 20_891, indexed: 20_888, permanentlyUnindexable: 0)),
                installedModelBytes: 0,
                availableModels: [],
                isSearchAvailable: true
            ))

        #expect(
            presentation.statusText
                == L10n.string("mlsearch.status_ready \(MLSmartSearchPresentation.productName)")
        )
        #expect(presentation.detailText != nil)
        #expect(presentation.progressFraction == nil)
        #expect(presentation.presentsAsReady)
        #expect(presentation.indexedCount == 20_888)
        #expect(presentation.totalCount == 20_891)
    }

    @Test func downloadShowsByteProgress() {
        let presentation = MLSmartSearchPresentation(
            snapshot: MLSmartSearchSnapshot(
                isEnabled: true,
                selectedModelID: nil,
                phase: .downloading(MLModelTransferProgress(bytesReceived: 25, totalBytes: 100)),
                installedModelBytes: 0,
                availableModels: [],
                isSearchAvailable: false
            ))

        #expect(presentation.progressFraction == 0.25)
        #expect(presentation.detailText != nil)
        #expect(presentation.isBusy)
    }

    @Test func aggregateProgressUsesWorkUnitsWithoutPresentingThemAsPhotos() {
        let aggregate = MLSmartSearchAggregateProgress(
            totalWorkUnits: 300,
            settledWorkUnits: 120,
            permanentlyUnavailableAssets: 2
        )
        let presentation = MLSmartSearchPresentation(
            snapshot: MLSmartSearchSnapshot(
                isEnabled: true,
                selectedModelID: nil,
                phase: .selectingModel,
                installedModelBytes: 0,
                availableModels: [],
                isSearchAvailable: true,
                indexingState: .indexing(aggregate)
            ))

        #expect(presentation.statusText == L10n.string("mlsearch.status_indexing"))
        #expect(presentation.progressFraction == 0.4)
        // Mirror the production call: the key is looked up through
        // String.LocalizationValue interpolation so the catalog entry with
        // its "%lld" placeholder is resolved instead of the literal key.
        #expect(presentation.detailText == L10n.string("mlsearch.work_progress_percent \(40)"))
        #expect(presentation.indexedCount == 120)
        #expect(presentation.totalCount == 300)
    }

    @Test func finishedIndexStaysCalmAndKeepsUnanalyzedMediaBehindTheInfo() {
        let progress = MLSmartSearchAggregateProgress(
            totalWorkUnits: 100, settledWorkUnits: 100, permanentlyUnavailableAssets: 8,
            unavailableAssetReasons: [.analysisFailed: 8])
        let presentation = MLSmartSearchPresentation(
            snapshot: MLSmartSearchSnapshot(
                isEnabled: true,
                selectedModelID: MLModelID("model"),
                phase: .ready(.init(total: 100, indexed: 92, permanentlyUnindexable: 8)),
                installedModelBytes: 0,
                availableModels: [],
                isSearchAvailable: true,
                indexingState: .ready(progress)
            ))

        #expect(presentation.presentsAsReady)
        #expect(presentation.detailText == nil)
        #expect(!presentation.canRetry)
        let note = try? #require(presentation.unavailableNote)
        #expect(note?.hasPrefix(L10n.string("mlsearch.unavailable_note \(8)")) == true)
        #expect(note?.contains(L10n.string("mlsearch.failure_analysis")) == true)
    }

    @Test func completeIndexHasNoInfo() {
        let progress = MLSmartSearchAggregateProgress(
            totalWorkUnits: 10, settledWorkUnits: 10, permanentlyUnavailableAssets: 0)
        let presentation = MLSmartSearchPresentation(
            snapshot: MLSmartSearchSnapshot(
                isEnabled: true, selectedModelID: MLModelID("model"),
                phase: .ready(.init(total: 10, indexed: 10, permanentlyUnindexable: 0)),
                installedModelBytes: 0, availableModels: [], isSearchAvailable: true, indexingState: .ready(progress)))
        #expect(presentation.unavailableNote == nil)
    }

    @Test func modelThatDoesNotFitNamesTheSpaceItNeeds() {
        let required: Int64 = 1_000_000_000
        let snapshot = MLSmartSearchSnapshot(
            isEnabled: true,
            selectedModelID: MLModelID("model"),
            phase: .failed(
                MLSmartSearchFailure(
                    kind: .insufficientStorage, isRetryable: true, debugDescription: "", requiredBytes: required)),
            installedModelBytes: 0,
            availableModels: [],
            isSearchAvailable: true,
            indexingState: .idle
        )
        let model = MLSmartSearchModelPresentation(snapshot: snapshot)
        #expect(model.statusText == L10n.string("mlsearch.status_failed_space"))
        #expect(model.detailText == L10n.string("mlsearch.space_required \(L10n.fileSize(required))"))
        #expect(model.canRetry)
        let overall = MLSmartSearchPresentation(snapshot: snapshot)
        #expect(overall.statusText == model.statusText)
        #expect(overall.canRetry)
    }

    @Test func enabledSearchWithoutAModelAsksForOne() {
        let presentation = MLSmartSearchPresentation(
            snapshot: MLSmartSearchSnapshot(
                isEnabled: true,
                selectedModelID: nil,
                phase: .selectingModel,
                installedModelBytes: 0,
                availableModels: [],
                isSearchAvailable: false,
                indexingState: .idle
            ))

        #expect(presentation.statusText == L10n.string("mlsearch.status_select_model"))
    }
}

/// Shared controller behavior that platform views rely on: the developer-artifact import owns
/// the security-scope lifetime (views own no filesystem lifecycle), and the atomic state store
/// surfaces write failures instead of swallowing them.
@Suite struct MLSmartSearchControllerTests {
    private final class ScopeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var beginCount = 0
        private(set) var endCount = 0
        /// Set when `end` fired: whether the install had already completed at that moment.
        private(set) var installCompleteWhenEnded: Bool?

        func recordBegin() { lock.withLock { beginCount += 1 } }
        func recordEnd(installComplete: Bool) {
            lock.withLock {
                endCount += 1
                installCompleteWhenEnded = installComplete
            }
        }
        var state: (begins: Int, ends: Int, installCompleteWhenEnded: Bool?) {
            lock.withLock { (beginCount, endCount, installCompleteWhenEnded) }
        }
    }

    private struct UnusedTransport: MLModelArtifactTransport {
        func download(
            from url: URL,
            to destination: URL,
            expectedByteCount: Int64,
            progress: @escaping @Sendable (Int64, Int64?) async -> Void
        ) async throws {
            throw URLError(.fileDoesNotExist)
        }
    }

    private final class NoopRuntimeProvider: MLSmartSearchRuntimeProvider {
        struct NoRuntime: Error {}
        func makeSession(
            model: MLInstalledModel,
            store: any MLIndexStore,
            shouldContinueIndexing: @escaping @Sendable () -> Bool
        ) async throws -> any MLSmartSearchSession {
            throw NoRuntime()
        }
    }

    private final class InMemoryStoreProvider: MLIndexStoreProvider, @unchecked Sendable {
        let store = InMemoryMLIndexStore()
        func openStore() -> (any MLIndexStore)? { store }
        func closeStore() {}
    }

    private actor BlockingNativeSearchFactory {
        private let result: (any MLNativeSearchServing)?
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var started = false

        init(result: (any MLNativeSearchServing)? = nil) {
            self.result = result
        }

        func make() async -> (any MLNativeSearchServing)? {
            started = true
            await withCheckedContinuation { continuation = $0 }
            return result
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private actor BlockingCatalogProvider: MLModelCatalogProvider {
        private let value: MLModelCatalog
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var started = false

        init(_ value: MLModelCatalog) {
            self.value = value
        }

        func catalog() async throws -> MLModelCatalog {
            started = true
            await withCheckedContinuation { continuation = $0 }
            return value
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private actor RestoredNativeSearch: MLNativeSearchServing {
        private let results: [PhotoUID]
        private let restoredProgress = MLDerivedPipelineProgress(
            total: 1,
            completed: 1,
            skipped: 0,
            permanentFailure: 0,
            retryPending: 0,
            generation: 1
        )

        init(results: [PhotoUID]) {
            self.results = results
        }

        func availableBackends() -> Set<MLSearchBackend> { [.recognizedText] }

        /// The double simulates a restored library whose OCR index already holds one entry.
        func hasIndexedTextEntries() -> Bool { true }

        func indexQuantum(
            assets: [MLPipelineAssetRevision],
            libraryGeneration: UInt64,
            allowsDestructiveReconciliation: Bool,
            destructiveReconciliationIsAuthorized: @escaping @Sendable () async -> Bool,
            maximumAssets: Int,
            maximumConcurrentAssets: Int,
            shouldContinue: @escaping @Sendable () -> Bool,
            observer: MLDerivedPipelineObserver
        ) -> MLDerivedPipelinePassOutcome {
            observer.report(restoredProgress)
            return MLDerivedPipelinePassOutcome(reason: .drained, progress: restoredProgress)
        }

        func search(_ text: String, scope: MLSearchScope, limit: Int) -> [PhotoUID] {
            Array(results.prefix(limit))
        }

        func progress() -> MLDerivedPipelineProgress { restoredProgress }
        func purge() {}
        func shutdown() {}
    }

    private func makeColdStartLifecycle(
        root: URL,
        state: MLSmartSearchPersistentState,
        catalogProvider: any MLModelCatalogProvider = StaticMLModelCatalogProvider(.init(entries: [])),
        assetInventory: MLAssetInventorySnapshot = .authoritative([]),
        nativeSearchFactory: @escaping @Sendable () async -> (any MLNativeSearchServing)?
    ) throws -> MLSmartSearchLifecycle {
        let layout = MLModelInstallLayout(rootDirectory: root)
        let stateStore = FileMLSmartSearchStateStore(layout: layout)
        try stateStore.save(state)
        return MLSmartSearchLifecycle(
            dependencies: .init(
                catalog: .init(entries: []),
                catalogProvider: catalogProvider,
                layout: layout,
                stateStore: stateStore,
                installer: MLModelInstaller(layout: layout, transport: UnusedTransport()),
                storeProvider: InMemoryStoreProvider(),
                runtimeProvider: NoopRuntimeProvider(),
                assetsProvider: { assetInventory },
                nativeSearchFactory: nativeSearchFactory,
                advertisedNativeSearchBackends: [.recognizedText, .documentText],
                governor: MLAlwaysPermitsIndexing(),
                allowsDeveloperModels: false
            ))
    }

    @discardableResult
    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ predicate: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }

    @MainActor
    @discardableResult
    private func waitUntilMainActor(
        timeout: Duration = .seconds(10),
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    @Test @MainActor func coldStartPublishesPersistedEnablementWhileNativeStartupIsBlocked() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-controller-cold-start-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = BlockingNativeSearchFactory()
        let lifecycle = try makeColdStartLifecycle(
            root: root,
            state: MLSmartSearchPersistentState(isEnabled: true),
            nativeSearchFactory: { await factory.make() }
        )
        let controller = MLSmartSearchController(lifecycle: lifecycle)

        #expect(await waitUntil { await factory.started })
        #expect(await waitUntilMainActor { controller.snapshot.isEnabled })
        #expect(controller.presentation.statusText != L10n.string("mlsearch.status_disabled"))
        // The native index has not been created yet, so the OCR scope stays hidden.
        #expect(controller.availableSearchScopes == [.all])

        await factory.release()
        await lifecycle.shutdown()
    }

    @Test @MainActor func coldStartPublishesRestoredNativeSearchBeforeCatalogStartupCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-controller-restored-search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = PhotoUID(volumeID: "volume", nodeID: "restored-ocr-result")
        let nativeSearch = RestoredNativeSearch(results: [expected])
        let catalogProvider = BlockingCatalogProvider(.init(entries: []))
        let lifecycle = try makeColdStartLifecycle(
            root: root,
            state: MLSmartSearchPersistentState(isEnabled: true),
            catalogProvider: catalogProvider,
            assetInventory: .authoritative([expected]),
            nativeSearchFactory: { nativeSearch }
        )
        let controller = MLSmartSearchController(lifecycle: lifecycle)

        #expect(await waitUntil { await catalogProvider.started })
        #expect(await waitUntilMainActor { controller.snapshot.isSearchAvailable })
        #expect(controller.snapshot.isEnabled)
        #expect(controller.availableSearchScopes == [.all, .text])
        #expect(try await lifecycle.searchUIDs("invoice", scope: .text) == [expected])

        await catalogProvider.release()
        await lifecycle.shutdown()
    }

    @Test @MainActor func developerImportHoldsTheSecurityScopeUntilInstallCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-controller-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)

        let entry = MLModelCatalogEntry(
            id: MLModelID("dev-model"),
            displayName: "dev-model",
            family: "Test",
            descriptor: MLModelDescriptor(identifier: "dev-model", version: 1, embeddingDimension: 4),
            tokenizerID: "t",
            preprocessingID: "p",
            license: .mit,
            releaseTrack: .production,
            estimatedInstalledBytes: 1,
            downloadPlan: nil
        )
        let installer = MLModelInstaller(layout: layout, transport: UnusedTransport())
        let lifecycle = MLSmartSearchLifecycle(
            dependencies: .init(
                catalog: MLModelCatalog(entries: [entry]),
                layout: layout,
                stateStore: FileMLSmartSearchStateStore(layout: layout),
                installer: installer,
                storeProvider: InMemoryStoreProvider(),
                runtimeProvider: NoopRuntimeProvider(),
                assetsProvider: { .authoritative([]) },
                governor: MLAlwaysPermitsIndexing(),
                allowsDeveloperModels: true
            ))

        // The developer artifact the user "picked".
        let artifact = root.appendingPathComponent("picked-artifact", isDirectory: true)
        let model = artifact.appendingPathComponent("Test.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: model.appendingPathComponent("model.bin"))

        let recorder = ScopeRecorder()
        let access = MLScopedArtifactAccess(
            begin: { _ in
                recorder.recordBegin()
                return true
            },
            end: { _ in
                // Installation must be durable before the scoped access closes. The recorder checks that
                // no copy or hash work depends on the released URL.
                recorder.recordEnd(installComplete: installer.anyInstalledRecord(for: entry) != nil)
            }
        )
        await lifecycle.start()
        let controller = MLSmartSearchController(lifecycle: lifecycle, artifactAccess: access)
        await lifecycle.enable(with: entry.id)

        controller.installDeveloperModel(from: artifact, for: entry.id)

        #expect(await waitUntil { recorder.state.ends == 1 })
        let state = recorder.state
        #expect(state.begins == 1)
        #expect(state.ends == 1)
        #expect(state.installCompleteWhenEnded == true)
        #expect(installer.anyInstalledRecord(for: entry) != nil)
    }
}

/// The atomic file store must surface write failures (journal writes may never be lost
/// silently) and keep the existing state readable when a write cannot happen.
@Suite struct FileMLSmartSearchStateStoreTests {
    @Test func saveThrowsWhenTheStateFileCannotBeWritten() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-statestore-\(UUID().uuidString)")
        // Occupy the root path with a plain file: directory creation and the atomic write
        // below it must fail loudly, not silently.
        try Data("blocker".utf8).write(to: base)
        defer { try? FileManager.default.removeItem(at: base) }

        let store = FileMLSmartSearchStateStore(layout: MLModelInstallLayout(rootDirectory: base))
        #expect(throws: (any Error).self) {
            try store.save(MLSmartSearchPersistentState(isEnabled: true))
        }
        #expect(try store.load() == nil)
    }

    @Test func saveIsAtomicAndRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-statestore-ok-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileMLSmartSearchStateStore(layout: MLModelInstallLayout(rootDirectory: root))

        let state = MLSmartSearchPersistentState(
            isEnabled: true,
            selectedModelID: MLModelID("model-a"),
            activatedRevision: "rev1",
            activatedDescriptor: MLModelDescriptor(
                identifier: "model-a",
                version: 3,
                embeddingDimension: 512
            ),
            pendingOperation: .switchModel(from: MLModelID("model-a"), to: MLModelID("model-b"))
        )
        try store.save(state)
        #expect(try store.load() == state)

        store.clear()
        #expect(try store.load() == nil)
    }

    @Test func stateWithoutActivatedDescriptorRemainsReadable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-statestore-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let store = FileMLSmartSearchStateStore(layout: layout)
        try store.save(
            MLSmartSearchPersistentState(
                isEnabled: true,
                selectedModelID: MLModelID("model-a"),
                activatedRevision: "rev1"
            ))

        let encoded = try Data(contentsOf: layout.stateFileURL)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "activatedDescriptor")
        try JSONSerialization.data(withJSONObject: object).write(to: layout.stateFileURL, options: .atomic)

        let restored = try #require(try store.load())
        #expect(restored.activatedRevision == "rev1")
        #expect(restored.activatedDescriptor == nil)
    }

    @Test func incompleteStateIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-statestore-incomplete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let store = FileMLSmartSearchStateStore(layout: layout)
        try store.save(
            MLSmartSearchPersistentState(
                isEnabled: true,
                selectedModelID: MLModelID("model-a")
            ))

        let encoded = try Data(contentsOf: layout.stateFileURL)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["isEnabled"] = nil
        try JSONSerialization.data(withJSONObject: object).write(to: layout.stateFileURL, options: .atomic)

        #expect(throws: (any Error).self) {
            _ = try store.load()
        }
    }

    @Test func corruptStateIsNotSilentlyTreatedAsDisabled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-statestore-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: layout.stateFileURL)

        let store = FileMLSmartSearchStateStore(layout: layout)
        #expect(throws: (any Error).self) {
            _ = try store.load()
        }
    }
}

@Suite struct MLSmartSearchStartSwitchTests {
    private func snapshot(
        isEnabled: Bool = false, isStartPending: Bool = false, startIntent: UInt64
    ) -> MLSmartSearchSnapshot {
        MLSmartSearchSnapshot(
            isEnabled: isEnabled, selectedModelID: nil, phase: .disabled, installedModelBytes: 0,
            isStartPending: isStartPending, startIntent: startIntent, availableModels: [], isSearchAvailable: false)
    }

    @Test func aTapShowsAtOnceAndAnOlderSnapshotCannotUndoIt() {
        var start = MLSmartSearchStartSwitch()
        let on = start.request(on: true)
        #expect(start.isStarting(snapshot(startIntent: 0)), "on at once, before the lifecycle answers")

        start.apply(snapshot(startIntent: on - 1))
        #expect(start.isStarting(snapshot(startIntent: on - 1)))

        start.apply(snapshot(isStartPending: true, startIntent: on))
        #expect(start.isStarting(snapshot(isStartPending: true, startIntent: on)))
    }

    @Test func switchingOffWinsOverAStalePendingSnapshot() {
        var start = MLSmartSearchStartSwitch()
        let on = start.request(on: true)
        start.apply(snapshot(isStartPending: true, startIntent: on))
        let off = start.request(on: false)

        // The pending snapshot is older than the switch-off: the switch stays off, it does not spring back.
        start.apply(snapshot(isStartPending: true, startIntent: on))
        #expect(!start.isStarting(snapshot(isStartPending: true, startIntent: on)))

        start.apply(snapshot(startIntent: off))
        #expect(!start.isStarting(snapshot(startIntent: off)))
    }

    @Test func onOffOnNeverFlickersOff() {
        var start = MLSmartSearchStartSwitch()
        _ = start.request(on: true)
        _ = start.request(on: false)
        let lastOn = start.request(on: true)

        for intent in 1..<lastOn {
            let stale = snapshot(isStartPending: intent == 1, startIntent: intent)
            start.apply(stale)
            #expect(start.isStarting(stale), "a snapshot of an earlier intent must not show the switch off")
        }
    }

    @Test func aRefusedSwitchOnSettlesOff() {
        var start = MLSmartSearchStartSwitch()
        let on = start.request(on: true)

        start.refused(on)

        #expect(!start.isStarting(snapshot(startIntent: 0)))
    }

    @Test func aNewControllerCountsOnFromTheLifecycleNumber() {
        var start = MLSmartSearchStartSwitch()
        start.apply(snapshot(startIntent: 7))

        let next = start.request(on: true)

        #expect(next == 8, "a lifecycle that already applied intent 7 must accept the next tap")
    }

    @Test func anEnabledSearchIsNoLongerStarting() {
        var start = MLSmartSearchStartSwitch()
        let on = start.request(on: true)
        #expect(!start.isStarting(snapshot(isEnabled: true, startIntent: on)))
    }
}
