import CryptoKit
import Foundation
import PhotosCore
import Testing

@testable import MLSearchCore

/// Universal lifecycle state machine: enable/download/activate/index, transactional model
/// switching, epoch isolation, crash recovery, and complete purge. Everything runs on real
/// Core components (installer, runner, in-memory or SQLite stores) with scripted transports,
/// embedders and governors; no CoreML, no network.
@Suite struct MLSmartSearchLifecycleTests {
    private final class ScriptedTransport: MLModelArtifactTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var payloads: [URL: Data]
        private var failuresRemaining: [URL: Int]
        private let failure: any Error
        private(set) var downloads = 0
        private var blocksNext = false
        private var blocked = false
        private var release: CheckedContinuation<Void, Never>?
        private var cancelledWhileBlocked = false

        init(
            payloads: [URL: Data], failFirst: [URL: Int] = [:],
            failure: any Error = URLError(.networkConnectionLost)
        ) {
            self.payloads = payloads
            self.failuresRemaining = failFirst
            self.failure = failure
        }

        func download(
            from url: URL,
            to destination: URL,
            expectedByteCount: Int64,
            progress: @escaping @Sendable (Int64, Int64?) async -> Void
        ) async throws {
            let blocks = lock.withLock {
                defer { blocksNext = false }
                return blocksNext
            }
            if blocks {
                // Like the URLSession transport, a cancelled download ends at once.
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        let resumeNow = lock.withLock {
                            guard !cancelledWhileBlocked else { return true }
                            blocked = true
                            release = continuation
                            return false
                        }
                        if resumeNow { continuation.resume() }
                    }
                } onCancel: {
                    let continuation = lock.withLock {
                        cancelledWhileBlocked = true
                        blocked = false
                        defer { release = nil }
                        return release
                    }
                    continuation?.resume()
                }
                try Task.checkCancellation()
            }
            let payload: Data = try lock.withLock {
                downloads += 1
                if let remaining = failuresRemaining[url], remaining > 0 {
                    failuresRemaining[url] = remaining - 1
                    throw failure
                }
                guard let data = payloads[url] else { throw URLError(.fileDoesNotExist) }
                return data
            }
            let total = Int64(payload.count)
            for step in 1...4 {
                await progress(total * Int64(step) / 4, total)
            }
            try payload.write(to: destination)
        }

        var downloadCount: Int { lock.withLock { downloads } }

        /// Holds the next download until `releaseBlockedDownload()`.
        func blockNextDownload() { lock.withLock { blocksNext = true } }
        var isBlocked: Bool { lock.withLock { blocked } }
        func releaseBlockedDownload() {
            let continuation = lock.withLock {
                blocked = false
                defer { release = nil }
                return release
            }
            continuation?.resume()
        }
    }

    private actor OneShotEmbeddingBarrier {
        private var armed = false
        private var blocked = false
        private var released = false
        private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func arm() {
            armed = true
            blocked = false
            released = false
            releaseContinuation = nil
        }

        func waitIfArmed() async {
            guard armed else { return }
            armed = false
            blocked = true
            blockedWaiters.forEach { $0.resume() }
            blockedWaiters.removeAll()
            if released {
                released = false
                return
            }
            await withCheckedContinuation { releaseContinuation = $0 }
        }

        func waitUntilBlocked() async {
            if blocked { return }
            await withCheckedContinuation { blockedWaiters.append($0) }
        }

        func release() {
            released = true
            releaseContinuation?.resume()
            releaseContinuation = nil
        }

        func releaseAndArmNext() {
            let pending = releaseContinuation
            arm()
            pending?.resume()
        }
    }

    private final class BlockingSuppressionRead: @unchecked Sendable {
        private let lock = NSLock()
        private let result: Set<PhotoUID>
        private var readContinuation: CheckedContinuation<Set<PhotoUID>, Error>?
        private var started = false
        private var cancelled = false
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

        init(result: Set<PhotoUID>) {
            self.result = result
        }

        func read() async throws -> Set<PhotoUID> {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Set<PhotoUID>, Error>) in
                    let resumeCancelled = lock.withLock {
                        started = true
                        startedWaiters.forEach { $0.resume() }
                        startedWaiters.removeAll()
                        guard !cancelled else { return true }
                        readContinuation = continuation
                        return false
                    }
                    if resumeCancelled {
                        continuation.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                self.cancel()
            }
        }

        func waitUntilStarted() async {
            await withCheckedContinuation { continuation in
                let alreadyStarted = lock.withLock {
                    if started { return true }
                    startedWaiters.append(continuation)
                    return false
                }
                if alreadyStarted { continuation.resume() }
            }
        }

        func waitUntilCancelled() async {
            await withCheckedContinuation { continuation in
                let alreadyCancelled = lock.withLock {
                    if cancelled { return true }
                    cancellationWaiters.append(continuation)
                    return false
                }
                if alreadyCancelled { continuation.resume() }
            }
        }

        private func cancel() {
            let continuation = lock.withLock {
                cancelled = true
                cancellationWaiters.forEach { $0.resume() }
                cancellationWaiters.removeAll()
                let continuation = readContinuation
                readContinuation = nil
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Embeds deterministic unit vectors and counts calls per uid.
    private final class CountingEmbedder: MLAssetEmbedder, @unchecked Sendable {
        private let lock = NSLock()
        private let barrier = OneShotEmbeddingBarrier()
        private(set) var calls: [PhotoUID: Int] = [:]
        private var delay: Duration?
        private var embeddingIndices: [PhotoUID: Int] = [:]
        private var cancelledEmbeddings = 0

        func embed(uid: PhotoUID, descriptor: MLModelDescriptor) async -> MLEmbeddingOutcome {
            await withTaskCancellationHandler {
                await barrier.waitIfArmed()
            } onCancel: {
                self.lock.withLock { self.cancelledEmbeddings += 1 }
            }
            if let delay = lock.withLock({ delay }) {
                try? await Task.sleep(for: delay)
            }
            lock.withLock { calls[uid, default: 0] += 1 }
            var vector = ContiguousArray<Float32>(repeating: 0, count: descriptor.embeddingDimension)
            let index =
                lock.withLock { embeddingIndices[uid] }
                ?? Int(UInt(bitPattern: uid.nodeID.hashValue) % UInt(descriptor.embeddingDimension))
            vector[index] = 1
            return .embedded(vector)
        }

        func callCount(_ uid: PhotoUID) -> Int { lock.withLock { calls[uid] ?? 0 } }
        var totalCalls: Int { lock.withLock { calls.values.reduce(0, +) } }
        var cancellationCount: Int { lock.withLock { cancelledEmbeddings } }
        func setDelay(_ value: Duration?) { lock.withLock { delay = value } }
        func setEmbeddingIndex(_ index: Int, for uid: PhotoUID) { lock.withLock { embeddingIndices[uid] = index } }
        func blockNextEmbedding() async { await barrier.arm() }
        func waitUntilEmbeddingStarted() async { await barrier.waitUntilBlocked() }
        func releaseEmbedding() async { await barrier.release() }
        func releaseEmbeddingAndBlockNext() async { await barrier.releaseAndArmNext() }
    }

    private struct FixedTextEncoder: MLTextQueryEncoder {
        func encode(text: String, descriptor: MLModelDescriptor) async throws -> ContiguousArray<Float32> {
            var vector = ContiguousArray<Float32>(repeating: 0, count: descriptor.embeddingDimension)
            vector[0] = 1
            return vector
        }
    }

    /// Builds real `MLSearchService` sessions over the shared store; scriptable failures.
    private final class ScriptedRuntimeProvider: MLSmartSearchRuntimeProvider, @unchecked Sendable {
        private let lock = NSLock()
        let embedder = CountingEmbedder()
        private var failNextMakeSession = false
        private var nextRuntimeFailure: MLRuntimeFailure?
        private var blockNextMakeSession = false
        private var makeSessionStarted = false
        private var releasedBlockedMakeSession = false
        private var blockedMakeSession: CheckedContinuation<Void, Never>?
        private var cancelledSessionLoads = 0
        private(set) var makeSessionAttempts = 0
        private(set) var sessionsBuilt = 0
        /// When set, `makeSession` returns this instead of a real service.
        var sessionOverride: (@Sendable (MLInstalledModel) -> any MLSmartSearchSession)?

        struct MakeSessionFailure: Error {}

        func failNext() { lock.withLock { failNextMakeSession = true } }
        func failNextRuntime(with failure: MLRuntimeFailure) {
            lock.withLock { nextRuntimeFailure = failure }
        }
        func blockNextSessionLoad() {
            lock.withLock {
                blockNextMakeSession = true
                releasedBlockedMakeSession = false
            }
        }
        func releaseBlockedSessionLoad() {
            let continuation = lock.withLock {
                releasedBlockedMakeSession = true
                let continuation = blockedMakeSession
                blockedMakeSession = nil
                return continuation
            }
            continuation?.resume()
        }
        var sessionLoadStarted: Bool { lock.withLock { makeSessionStarted } }
        var sessionLoadCancellations: Int { lock.withLock { cancelledSessionLoads } }
        var attemptCount: Int { lock.withLock { makeSessionAttempts } }
        var builtCount: Int { lock.withLock { sessionsBuilt } }

        func makeSession(
            model: MLInstalledModel,
            store: any MLIndexStore,
            shouldContinueIndexing: @escaping @Sendable () -> Bool
        ) async throws -> any MLSmartSearchSession {
            let result = lock.withLock {
                makeSessionAttempts += 1
                makeSessionStarted = true
                let fail = failNextMakeSession
                failNextMakeSession = false
                if !fail { sessionsBuilt += 1 }
                let runtimeFailure = nextRuntimeFailure
                nextRuntimeFailure = nil
                return (fail, runtimeFailure)
            }
            if result.0 { throw MakeSessionFailure() }
            if let runtimeFailure = result.1 { throw runtimeFailure }
            let shouldBlock = lock.withLock {
                if blockNextMakeSession {
                    blockNextMakeSession = false
                    return true
                }
                return false
            }
            if shouldBlock {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        let resumeImmediately = lock.withLock {
                            if releasedBlockedMakeSession { return true }
                            blockedMakeSession = continuation
                            return false
                        }
                        if resumeImmediately { continuation.resume() }
                    }
                } onCancel: {
                    self.lock.withLock { self.cancelledSessionLoads += 1 }
                }
            }
            if let sessionOverride {
                return sessionOverride(model)
            }
            return MLSearchService(
                descriptor: model.entry.descriptor,
                store: store,
                assetEmbedder: embedder,
                textEncoder: FixedTextEncoder(),
                scorer: ReferenceDotProductScorer(),
                runnerConfiguration: .init(chunkSize: 8),
                shouldContinue: shouldContinueIndexing
            )
        }
    }

    private final class InMemoryStoreProvider: MLIndexStoreProvider, @unchecked Sendable {
        let store = InMemoryMLIndexStore()
        private let lock = NSLock()
        private var closes = 0
        func openStore() -> (any MLIndexStore)? { store }
        func closeStore() { lock.withLock { closes += 1 } }
        var closeCount: Int { lock.withLock { closes } }
    }

    /// File-backed state store whose saves can be scripted to fail (journal-write faults).
    private final class FlakyStateStore: MLSmartSearchStateStore, @unchecked Sendable {
        struct WriteFailure: Error {}
        private let backing: FileMLSmartSearchStateStore
        private let lock = NSLock()
        private var failing = false
        private var failingActivationWrites = false
        private var failingWhere: (@Sendable (MLSmartSearchPersistentState) -> Bool)?

        init(layout: MLModelInstallLayout) {
            backing = FileMLSmartSearchStateStore(layout: layout)
        }

        func setFailing(_ value: Bool) { lock.withLock { failing = value } }
        func setFailingActivationWrites(_ value: Bool) {
            lock.withLock { failingActivationWrites = value }
        }
        func setFailing(where predicate: (@Sendable (MLSmartSearchPersistentState) -> Bool)?) {
            lock.withLock { failingWhere = predicate }
        }
        func load() throws -> MLSmartSearchPersistentState? { try backing.load() }
        func save(_ state: MLSmartSearchPersistentState) throws {
            if lock.withLock({
                failing || (failingActivationWrites && state.activatedRevision != nil)
                    || failingWhere?(state) == true
            }) {
                throw WriteFailure()
            }
            try backing.save(state)
        }
        func clear() { backing.clear() }
    }

    private final class TrackingSession: MLSmartSearchSession, @unchecked Sendable {
        let descriptor: MLModelDescriptor
        private let indexFails: Bool
        private let lock = NSLock()
        private var indexes = 0
        private var shutdowns = 0

        init(descriptor: MLModelDescriptor, indexFails: Bool = false) {
            self.descriptor = descriptor
            self.indexFails = indexFails
        }

        func index(_ assets: [PhotoUID], observer: MLIndexPassObserver) async -> MLIndexPassOutcome {
            lock.withLock { indexes += 1 }
            return MLIndexPassOutcome(
                report: MLIndexBatchReport(),
                ranToCompletion: false,
                newPermanentFailures: [],
                progress: MLIndexProgress(
                    phase: indexFails ? .failed(message: "fixture storage failure") : .idle,
                    descriptor: descriptor)
            )
        }

        func search(_ text: String, limit: Int) async throws -> MLSearchResults {
            MLSearchResults(descriptor: descriptor, queryText: text, results: [])
        }

        func releaseMemory() async {}
        func shutdown() async { lock.withLock { shutdowns += 1 } }

        var indexCount: Int { lock.withLock { indexes } }
        var shutdownCount: Int { lock.withLock { shutdowns } }
    }

    private final class FixedSemanticSession: MLSmartSearchSession, @unchecked Sendable {
        let descriptor: MLModelDescriptor
        private let permanentlyUnavailable: Set<PhotoUID>
        private let suppressionRead: BlockingSuppressionRead?
        private let duringBatch: @Sendable () -> Void

        init(
            descriptor: MLModelDescriptor,
            permanentlyUnavailable: Set<PhotoUID> = [],
            suppressionRead: BlockingSuppressionRead? = nil,
            duringBatch: @escaping @Sendable () -> Void = {}
        ) {
            self.descriptor = descriptor
            self.permanentlyUnavailable = permanentlyUnavailable
            self.suppressionRead = suppressionRead
            self.duringBatch = duringBatch
        }

        func index(_ assets: [PhotoUID], observer: MLIndexPassObserver) async -> MLIndexPassOutcome {
            let permanentFailure = permanentlyUnavailable.intersection(Set(assets)).count
            let progress = MLIndexProgress(
                phase: .completed,
                descriptor: descriptor,
                totalAssets: assets.count,
                indexed: assets.count - permanentFailure,
                permanentFailure: permanentFailure
            )
            let outcome = MLIndexPassOutcome(
                report: MLIndexBatchReport(
                    total: assets.count,
                    indexed: assets.count - permanentFailure,
                    permanentFailure: permanentFailure
                ),
                ranToCompletion: true,
                newPermanentFailures: permanentlyUnavailable.intersection(Set(assets)),
                progress: progress
            )
            observer.reportProgressUpdated(progress)
            return outcome
        }

        func permanentlyUnavailableAssetUIDs(_ assets: [PhotoUID]) async throws -> Set<PhotoUID> {
            if let suppressionRead {
                return try await suppressionRead.read()
            }
            return permanentlyUnavailable.intersection(Set(assets))
        }

        func search(_ text: String, limit: Int) async throws -> MLSearchResults {
            MLSearchResults(descriptor: descriptor, queryText: text, results: [])
        }

        func searchBatch(
            _ texts: [String], limit: Int, shouldContinue: @escaping @Sendable () -> Bool
        ) async throws -> MLSearchBatchResults {
            duringBatch()
            return MLSearchBatchResults(
                results: texts.map { MLSearchResults(descriptor: descriptor, queryText: $0, results: []) },
                scannedUIDs: MLScannedUIDMembership([]))
        }

        func releaseMemory() async {}
        func shutdown() async {}
    }

    private final class SessionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TrackingSession] = []

        func make(_ model: MLInstalledModel) -> TrackingSession {
            let session = TrackingSession(descriptor: model.entry.descriptor)
            lock.withLock { storage.append(session) }
            return session
        }

        var sessions: [TrackingSession] { lock.withLock { storage } }
    }

    private final class MutableAssets: @unchecked Sendable {
        private let lock = NSLock()
        private var inventory: MLAssetInventorySnapshot
        init(_ uids: [PhotoUID]) { inventory = .authoritative(uids) }
        var current: MLAssetInventorySnapshot { lock.withLock { inventory } }
        func set(_ new: [PhotoUID]) { lock.withLock { inventory = .authoritative(new) } }
        func setSnapshot(_ new: MLAssetInventorySnapshot) { lock.withLock { inventory = new } }
        func setHydrating(_ visible: [PhotoUID]) {
            lock.withLock {
                inventory = MLAssetInventorySnapshot(
                    uids: visible,
                    isAuthoritative: false
                )
            }
        }
        func beginHydration() { lock.withLock { inventory = .hydrating } }
    }

    private final class ToggleGovernor: MLIndexingGovernor, @unchecked Sendable {
        private let lock = NSLock()
        private var permitted = true
        private var checks = 0
        var checkCount: Int { lock.withLock { checks } }
        func permitsIndexing() -> Bool {
            lock.withLock {
                checks += 1
                return permitted
            }
        }
        func set(_ value: Bool) { lock.withLock { permitted = value } }
    }

    private final class RecordingNativeSearch: MLNativeSearchServing, @unchecked Sendable {
        private let lock = NSLock()
        private let results: [PhotoUID]
        private let permanentlyUnavailable: Set<PhotoUID>
        private let suppressionRead: BlockingSuppressionRead?
        private let deferredCount: Int
        private let afterProgressReport: (@Sendable () async -> Void)?
        private var indexedAssets: [MLPipelineAssetRevision] = []
        private var indexes = 0
        private var shutdowns = 0

        init(
            results: [PhotoUID],
            initiallyIndexed: [PhotoUID] = [],
            permanentlyUnavailable: Set<PhotoUID> = [],
            suppressionRead: BlockingSuppressionRead? = nil,
            deferredCount: Int = 0,
            afterProgressReport: (@Sendable () async -> Void)? = nil
        ) {
            self.results = results
            self.deferredCount = deferredCount
            self.afterProgressReport = afterProgressReport
            self.permanentlyUnavailable = permanentlyUnavailable
            self.suppressionRead = suppressionRead
            indexedAssets = initiallyIndexed.compactMap {
                try? MLPipelineAssetRevision(
                    uid: $0,
                    sourceRevision: "uid-v1:\($0.volumeID):\($0.nodeID)"
                )
            }
        }

        func availableBackends() async -> Set<MLSearchBackend> { [.recognizedText] }

        func index(
            assets: [MLPipelineAssetRevision],
            shouldContinue: @escaping @Sendable () -> Bool,
            observer: MLDerivedPipelineObserver
        ) async -> MLDerivedPipelinePassOutcome {
            await performIndex(
                assets: assets,
                allowsDestructiveReconciliation: true,
                shouldContinue: shouldContinue,
                observer: observer
            )
        }

        func indexQuantum(
            assets: [MLPipelineAssetRevision],
            libraryGeneration: UInt64,
            allowsDestructiveReconciliation: Bool,
            maximumAssets: Int,
            maximumConcurrentAssets: Int,
            shouldContinue: @escaping @Sendable () -> Bool,
            observer: MLDerivedPipelineObserver
        ) async -> MLDerivedPipelinePassOutcome {
            await performIndex(
                assets: assets,
                allowsDestructiveReconciliation: allowsDestructiveReconciliation,
                shouldContinue: shouldContinue,
                observer: observer
            )
        }

        func indexQuantum(
            assets: [MLPipelineAssetRevision],
            libraryGeneration: UInt64,
            allowsDestructiveReconciliation: Bool,
            destructiveReconciliationIsAuthorized: @escaping @Sendable () async -> Bool,
            maximumAssets: Int,
            maximumConcurrentAssets: Int,
            shouldContinue: @escaping @Sendable () -> Bool,
            observer: MLDerivedPipelineObserver
        ) async -> MLDerivedPipelinePassOutcome {
            let authorized: Bool
            if allowsDestructiveReconciliation {
                authorized = await destructiveReconciliationIsAuthorized()
            } else {
                authorized = false
            }
            return await performIndex(
                assets: assets,
                allowsDestructiveReconciliation: authorized,
                shouldContinue: shouldContinue,
                observer: observer
            )
        }

        private func performIndex(
            assets: [MLPipelineAssetRevision],
            allowsDestructiveReconciliation: Bool,
            shouldContinue: @escaping @Sendable () -> Bool,
            observer: MLDerivedPipelineObserver
        ) async -> MLDerivedPipelinePassOutcome {
            lock.withLock { indexes += 1 }
            guard shouldContinue() else {
                return MLDerivedPipelinePassOutcome(
                    reason: .policySuspended,
                    progress: MLDerivedPipelineProgress(
                        total: assets.count,
                        completed: 0,
                        skipped: 0,
                        permanentFailure: 0,
                        retryPending: 0,
                        generation: 0
                    )
                )
            }
            let visibleCount = lock.withLock {
                if allowsDestructiveReconciliation {
                    indexedAssets = assets
                } else {
                    var seen = Set(indexedAssets.map(\.uid))
                    indexedAssets.append(contentsOf: assets.filter { seen.insert($0.uid).inserted })
                }
                return indexedAssets.count
            }
            let permanentFailure = permanentlyUnavailable.intersection(Set(assets.map(\.uid))).count
            let outcome = MLDerivedPipelinePassOutcome(
                reason: deferredCount > 0 ? .retryPending : .drained,
                progress: MLDerivedPipelineProgress(
                    total: visibleCount,
                    completed: max(0, visibleCount - permanentFailure - deferredCount),
                    skipped: 0,
                    permanentFailure: permanentFailure,
                    retryPending: deferredCount,
                    unavailableAssets: permanentFailure,
                    generation: 1
                )
            )
            observer.report(outcome.progress)
            if let afterProgressReport { await afterProgressReport() }
            return outcome
        }

        func search(_ text: String, scope: MLSearchScope, limit: Int) async -> [PhotoUID] {
            Array(results.prefix(limit))
        }

        func progress() async -> MLDerivedPipelineProgress {
            let count = lock.withLock { indexedAssets.count }
            return MLDerivedPipelineProgress(
                total: count,
                completed: count,
                skipped: 0,
                permanentFailure: 0,
                retryPending: 0,
                generation: count > 0 ? 1 : 0
            )
        }

        func unavailableAssetUIDs() async throws -> Set<PhotoUID> {
            if let suppressionRead {
                return try await suppressionRead.read()
            }
            return permanentlyUnavailable
        }

        func purge() async {}
        func shutdown() async { lock.withLock { shutdowns += 1 } }

        var indexedUIDs: [PhotoUID] { lock.withLock { indexedAssets.map(\.uid) } }
        var indexCount: Int { lock.withLock { indexes } }
        var shutdownCount: Int { lock.withLock { shutdowns } }
    }

    private actor RecordingCatalogProvider: MLModelCatalogProvider {
        private var value: MLModelCatalog
        private(set) var requestCount = 0

        init(_ value: MLModelCatalog) { self.value = value }

        func replace(_ value: MLModelCatalog) { self.value = value }

        func catalog() async throws -> MLModelCatalog {
            requestCount += 1
            return value
        }
    }

    private actor FailingCatalogProvider: MLModelCatalogProvider {
        struct Failure: Error {}
        func catalog() async throws -> MLModelCatalog { throw Failure() }
    }

    private actor FailingOnceCatalogProvider: MLModelCatalogProvider {
        private let value: MLModelCatalog
        private var failed = false

        init(_ value: MLModelCatalog) { self.value = value }

        func catalog() async throws -> MLModelCatalog {
            guard failed else {
                failed = true
                throw FailingCatalogProvider.Failure()
            }
            return value
        }
    }

    /// Answers each request by its script entry: fail, hold until the test fails it, or return the catalog
    /// (also for every request after the script).
    private actor ScriptedCatalogProvider: MLModelCatalogProvider {
        enum Step { case fail, hold }
        private let value: MLModelCatalog
        private var script: [Step]
        private var held: CheckedContinuation<Void, Never>?

        init(_ value: MLModelCatalog, script: [Step]) {
            self.value = value
            self.script = script
        }

        var isHolding: Bool { held != nil }
        private(set) var requestCount = 0

        func catalog() async throws -> MLModelCatalog {
            requestCount += 1
            guard !script.isEmpty else { return value }
            switch script.removeFirst() {
            case .fail:
                throw FailingCatalogProvider.Failure()
            case .hold:
                await withCheckedContinuation { held = $0 }
                throw FailingCatalogProvider.Failure()
            }
        }

        func failHeldRequest() {
            held?.resume()
            held = nil
        }
    }

    /// Holds its first request until the test fails it; later requests return the catalog at once.
    private actor GatedFirstCatalogProvider: MLModelCatalogProvider {
        private let value: MLModelCatalog
        private var requests = 0
        private var waiting: CheckedContinuation<Void, Never>?
        private var failWaiting = false

        init(_ value: MLModelCatalog) { self.value = value }

        var isWaiting: Bool { waiting != nil }

        func catalog() async throws -> MLModelCatalog {
            requests += 1
            guard requests == 1 else { return value }
            await withCheckedContinuation { waiting = $0 }
            if failWaiting { throw FailingCatalogProvider.Failure() }
            return value
        }

        func failWaitingRequest() {
            failWaiting = true
            waiting?.resume()
            waiting = nil
        }
    }

    private final class FreeSpace: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: Int64

        init(_ bytes: Int64) { self.bytes = bytes }

        var value: Int64 {
            get { lock.withLock { bytes } }
            set { lock.withLock { bytes = newValue } }
        }
    }

    private func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: "vol1", nodeID: id) }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    /// A developer model without a hosted artifact. Smart Search enabled with it runs native analysis
    /// only, because nothing can download.
    private func localModelEntry(id: String = "local-model") -> MLModelCatalogEntry {
        MLModelCatalogEntry(
            id: MLModelID(id),
            displayName: id,
            family: "Test",
            descriptor: MLModelDescriptor(identifier: id, version: 1, embeddingDimension: 4),
            tokenizerID: "test-tokenizer",
            preprocessingID: "test-preprocessing",
            license: .mit,
            releaseTrack: .developerOnly,
            estimatedInstalledBytes: 1,
            downloadPlan: nil
        )
    }

    private func retired(_ entry: MLModelCatalogEntry) -> MLModelCatalogEntry {
        MLModelCatalogEntry(
            id: entry.id, compatibilityKey: entry.compatibilityKey, displayName: entry.displayName,
            family: entry.family, role: entry.role, capabilities: entry.capabilities,
            sourceRevision: entry.sourceRevision, descriptor: entry.descriptor, tokenizerID: entry.tokenizerID,
            preprocessingID: entry.preprocessingID, runtimeContract: entry.runtimeContract,
            relevancePolicy: entry.relevancePolicy, runtimeResourcePaths: entry.runtimeResourcePaths,
            license: entry.license, releaseTrack: entry.releaseTrack, localizedMetadata: entry.localizedMetadata,
            estimatedInstalledBytes: entry.estimatedInstalledBytes, downloadPlan: entry.downloadPlan,
            releaseQualification: entry.releaseQualification, isRetired: true)
    }

    private func downloadableEntry(
        id: String,
        payload: Data,
        track: MLModelReleaseTrack = .production,
        includeQualification: Bool = true,
        revision: String = "rev1",
        descriptorVersion: Int = 1
    ) -> (MLModelCatalogEntry, URL) {
        let url = URL(string: "https://example.test/\(id)/\(revision)/weights.bin")!
        let qualification =
            track == .production && includeQualification
            ? MLModelReleaseQualification(
                artifactRevision: revision,
                hardwareModel: "test-device",
                osVersion: "test",
                peakResidentBytes: 1,
                imageP95Milliseconds: 1,
                textP95Milliseconds: 1,
                reachedSeriousThermalState: false,
                neuralEngineExecutionVerified: true,
                passed: true
            ) : nil
        let entry = MLModelCatalogEntry(
            id: MLModelID(id),
            displayName: id,
            family: "Test",
            descriptor: MLModelDescriptor(
                identifier: id,
                version: descriptorVersion,
                embeddingDimension: 4
            ),
            tokenizerID: "test-tokenizer",
            preprocessingID: "test-preprocessing",
            license: .mit,
            releaseTrack: track,
            estimatedInstalledBytes: Int64(payload.count),
            downloadPlan: MLModelDownloadPlan(
                revision: revision,
                items: [
                    .init(
                        url: url,
                        artifact: MLModelArtifactSpec(
                            relativePath: "Model.mlmodelc/weights.bin", sha256: sha256(payload),
                            byteCount: Int64(payload.count)))
                ]),
            releaseQualification: qualification
        )
        return (entry, url)
    }

    private func descriptorDriftedEntry(
        from entry: MLModelCatalogEntry,
        version: Int,
        downloadPlan: MLModelDownloadPlan? = nil
    ) -> MLModelCatalogEntry {
        MLModelCatalogEntry(
            id: entry.id,
            compatibilityKey: entry.compatibilityKey,
            displayName: entry.displayName,
            family: entry.family,
            role: entry.role,
            capabilities: entry.capabilities,
            sourceRevision: entry.sourceRevision,
            descriptor: MLModelDescriptor(
                identifier: entry.descriptor.identifier,
                version: version,
                embeddingDimension: entry.descriptor.embeddingDimension
            ),
            tokenizerID: entry.tokenizerID,
            preprocessingID: entry.preprocessingID,
            runtimeContract: entry.runtimeContract,
            relevancePolicy: entry.relevancePolicy,
            runtimeResourcePaths: entry.runtimeResourcePaths,
            license: entry.license,
            releaseTrack: entry.releaseTrack,
            localizedMetadata: entry.localizedMetadata,
            estimatedInstalledBytes: entry.estimatedInstalledBytes,
            downloadPlan: downloadPlan,
            releaseQualification: downloadPlan == nil ? nil : entry.releaseQualification
        )
    }

    private struct Harness {
        let lifecycle: MLSmartSearchLifecycle
        let layout: MLModelInstallLayout
        let stateStore: any MLSmartSearchStateStore
        let transport: ScriptedTransport
        let provider: ScriptedRuntimeProvider
        let storeProvider: InMemoryStoreProvider
        let assets: MutableAssets
        let governor: ToggleGovernor
        let resourceCoordinator: LibraryResourceCoordinator
    }

    private struct SuggestionCipher: MLDerivedDataCipher {
        private let key = SymmetricKey(data: Data(repeating: 42, count: 32))
        func seal(_ plaintext: Data, context: MLDerivedDataCipherContext) throws -> Data {
            try #require(
                AES.GCM.seal(plaintext, using: key, authenticating: Data(context.accountIdentifier.utf8)).combined)
        }
        func open(_ ciphertext: Data, context: MLDerivedDataCipherContext) throws -> Data {
            try AES.GCM.open(
                AES.GCM.SealedBox(combined: ciphertext), using: key,
                authenticating: Data(context.accountIdentifier.utf8))
        }
        func tokenDigest(normalizedToken: String, accountIdentifier: String, artifactNamespace: String) throws -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(normalizedToken.utf8), using: key))
        }
    }

    @Test func suggestionCacheWaitsForVerifiedActiveModel() async throws {
        let payload = Data("model".utf8)
        let (entry, url) = downloadableEntry(id: "cache-model", payload: payload)
        let harness = try makeHarness(
            catalog: .init(entries: [entry]), payloads: [url: payload], assets: [uid("a")],
            suggestionCacheEnabled: true)
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        await harness.lifecycle.start()
        harness.provider.blockNextSessionLoad()
        let activation = Task { await harness.lifecycle.enable(with: entry.id) }
        #expect(await waitUntil { harness.provider.sessionLoadStarted })
        #expect(await harness.lifecycle.suggestionCacheAccess() == nil)
        harness.provider.releaseBlockedSessionLoad()
        await activation.value
        await harness.lifecycle.shutdown()
    }

    @Test func disabledSearchCanPersistMetadataSuggestions() async throws {
        let harness = try makeHarness(
            catalog: .init(entries: []), payloads: [:], assets: [], suggestionCacheEnabled: true)
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        await harness.lifecycle.start()
        let lease = try #require(await harness.lifecycle.suggestionCacheAccess())
        let payload = Data("metadata-suggestions".utf8)
        try await lease.save(payload)
        #expect(await harness.lifecycle.suggestionCacheAccess()?.data == payload)
        await harness.lifecycle.shutdown()
        do {
            try await lease.save(payload)
            Issue.record("shutdown must retire metadata cache writes too")
        } catch MLSmartSearchQueryError.staleEpoch {}
    }

    @Test func nativeDeferredRetriesDoNotBlockCompletedSemanticSuggestions() async throws {
        let payload = Data("model".utf8)
        let (entry, url) = downloadableEntry(id: "deferred-native", payload: payload)
        let assets = [uid("a"), uid("b"), uid("c")]
        let progressDelivery = OneShotEmbeddingBarrier()
        await progressDelivery.arm()
        let harness = try makeHarness(
            catalog: .init(entries: [entry]), payloads: [url: payload], assets: assets,
            nativeSearch: RecordingNativeSearch(
                results: [], deferredCount: 1,
                afterProgressReport: { await progressDelivery.waitIfArmed() }))
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        harness.governor.set(false)
        await harness.lifecycle.start()
        let stream = await harness.lifecycle.snapshots()
        await harness.lifecycle.enable(with: entry.id)
        let terminal = await withTaskGroup(of: MLSmartSearchSnapshot?.self) { group in
            group.addTask {
                var governorOpened = false
                var nativeProgressDelivered = false
                for await snapshot in stream {
                    guard snapshot.isEnabled, snapshot.selectedModelID == entry.id else { continue }
                    // This fresh fixture publishes waiting after model preparation. Keep the
                    // native-only startup pass from satisfying the test before semantic indexing.
                    if !governorOpened, case .waiting = snapshot.phase {
                        governorOpened = true
                        harness.governor.set(true)
                        await harness.lifecycle.noteConditionsChanged()
                    }
                    // Keep the native pass alive until its admitted progress has actually arrived.
                    if !nativeProgressDelivered, case .indexing(let progress) = snapshot.indexingState,
                        progress.deferredWorkUnits > 0
                    {
                        nativeProgressDelivered = true
                        await progressDelivery.release()
                    }
                    guard nativeProgressDelivered else { continue }
                    switch snapshot.phase {
                    case .ready(let coverage), .waiting(let coverage):
                        if coverage.total == assets.count, coverage.isComplete { return snapshot }
                    default: break
                    }
                }
                return nil
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(300)) } catch { return nil }
                await progressDelivery.release()
                return nil
            }
            let snapshot = await group.next() ?? nil
            group.cancelAll()
            return snapshot
        }
        let current = await harness.lifecycle.currentSnapshot()
        let indexedCount = await harness.lifecycle.semanticIndexedAssetCount()
        await progressDelivery.release()
        await harness.lifecycle.shutdown()
        let snapshot = try #require(terminal, "the completed semantic pass must publish its state")
        #expect(indexedCount == assets.count)
        for state in [snapshot, current] {
            #expect(state.permitsAutomaticSuggestionGeneration)
            #expect(state.isVisualIndexComplete)
            if case .waiting(let progress) = state.indexingState {
                #expect(progress.deferredWorkUnits == 1)
                #expect(!progress.isComplete, "a deferred retry is not falsely reported as indexed")
            } else {
                Issue.record("deferred native work must remain waiting")
            }
        }
    }

    @Test(arguments: ["shutdown", "purge", "modelSwitch", "indexChange"])
    func suggestionCacheLeaseCannotOutliveItsState(_ retirement: String) async throws {
        let payload = Data("model".utf8)
        let (entry, url) = downloadableEntry(id: "cache-a", payload: payload)
        let (other, otherURL) = downloadableEntry(id: "cache-b", payload: payload)
        let harness = try makeHarness(
            catalog: .init(entries: [entry, other]), payloads: [url: payload, otherURL: payload], assets: [uid("a")],
            suggestionCacheEnabled: true)
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entry.id)
        for _ in 0..<200 where await harness.lifecycle.semanticIndexedAssetCount() == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await harness.lifecycle.semanticIndexedAssetCount() == 1)
        let lease = try #require(await harness.lifecycle.suggestionCacheAccess())
        let original = Data("completed-cache".utf8)
        #expect(await lease.isCurrent())
        try await lease.save(original)
        #expect(await harness.lifecycle.suggestionCacheAccess()?.data == original)
        switch retirement {
        case "shutdown": await harness.lifecycle.shutdown()
        case "purge": await harness.lifecycle.disableAndPurge()
        case "modelSwitch": await harness.lifecycle.select(other.id)
        default:
            harness.storeProvider.store.upsert([
                MLEmbeddingRecord(uid: uid("new"), descriptor: entry.descriptor, vector: [1, 0, 0, 0])
            ])
        }
        do {
            #expect(await !lease.isCurrent(), "retired read authority must not restore a stale snapshot")
            try await lease.save(Data("stale".utf8))
            Issue.record("retired cache lease wrote after \(retirement)")
        } catch MLSmartSearchQueryError.staleEpoch {}
        if ["purge", "modelSwitch"].contains(retirement) {
            #expect(
                !FileManager.default.fileExists(
                    atPath: harness.layout.rootDirectory.appendingPathComponent("suggestions-v1.enc").path))
        }
        await harness.lifecycle.shutdown()
    }

    @Test(arguments: [false, true]) func changedInventoryRevisionRejectsInFlightSuggestionEvidence(
        hydrating: Bool
    ) async throws {
        let payload = Data("model".utf8)
        let (entry, url) = downloadableEntry(id: "batch-revision", payload: payload)
        let initial = uid("initial")
        let added = uid("added")
        let harness = try makeHarness(catalog: .init(entries: [entry]), payloads: [url: payload], assets: [initial])
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        let assets = harness.assets
        assets.setSnapshot(.init(uids: [initial], isAuthoritative: true, sourceRevision: 1))
        harness.provider.sessionOverride = { model in
            FixedSemanticSession(descriptor: model.entry.descriptor) {
                if !hydrating {
                    assets.setSnapshot(.init(uids: [initial, added], isAuthoritative: true, sourceRevision: 2))
                }
            }
        }
        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entry.id)
        for _ in 0..<200 where await harness.lifecycle.semanticIndexedAssetCount() == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await harness.lifecycle.semanticIndexedAssetCount() == 1)
        if hydrating { assets.beginHydration() }
        do {
            _ = try await harness.lifecycle.searchSuggestionEvidence()
            Issue.record("A scan of the prior source revision must not become evidence for new inventory")
        } catch MLSmartSearchQueryError.staleEpoch {}
        await harness.lifecycle.shutdown()
    }

    private func makeHarness(
        catalog: MLModelCatalog,
        payloads: [URL: Data],
        assets: [PhotoUID],
        failFirst: [URL: Int] = [:],
        allowsDeveloperModels: Bool = true,
        root: URL? = nil,
        retryDelay: Duration = .seconds(60),
        closedGateRecheckDelay: Duration = .seconds(1),
        stateStoreOverride: (any MLSmartSearchStateStore)? = nil,
        storeProviderOverride: InMemoryStoreProvider? = nil,
        transportOverride: ScriptedTransport? = nil,
        catalogProvider: (any MLModelCatalogProvider)? = nil,
        nativeSearch: RecordingNativeSearch? = nil,
        nativeSearchFactoryOverride: (@Sendable () async -> (any MLNativeSearchServing)?)? = nil,
        advertisedNativeSearchBackends: Set<MLSearchBackend> = [],
        resourceCoordinator: LibraryResourceCoordinator? = nil,
        featureAvailability: AppFeatureAvailability = .available,
        indexingCapacityProfile: MLIndexingCapacityProfile = .constrained,
        catalogRefreshInterval: Duration = .seconds(15 * 60),
        suggestionCacheEnabled: Bool = false,
        freeSpace: FreeSpace? = nil
    ) throws -> Harness {
        let rootDir =
            root
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-lifecycle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let layout = MLModelInstallLayout(rootDirectory: rootDir)
        let transport = transportOverride ?? ScriptedTransport(payloads: payloads, failFirst: failFirst)
        let provider = ScriptedRuntimeProvider()
        let storeProvider = storeProviderOverride ?? InMemoryStoreProvider()
        let mutableAssets = MutableAssets(assets)
        let governor = ToggleGovernor()
        let resourceCoordinator =
            resourceCoordinator
            ?? LibraryResourceCoordinator(runtimeState: LibraryRuntimeState())
        let stateStore = stateStoreOverride ?? FileMLSmartSearchStateStore(layout: layout)
        let nativeSearchFactory: (@Sendable () async -> (any MLNativeSearchServing)?)?
        if let nativeSearchFactoryOverride {
            nativeSearchFactory = nativeSearchFactoryOverride
        } else if let nativeSearch {
            nativeSearchFactory = { nativeSearch }
        } else {
            nativeSearchFactory = nil
        }
        let lifecycle = MLSmartSearchLifecycle(
            dependencies: .init(
                catalog: catalog,
                catalogProvider: catalogProvider,
                layout: layout,
                stateStore: stateStore,
                installer: MLModelInstaller(
                    layout: layout, transport: transport, availableCapacity: { _ in freeSpace?.value }),
                storeProvider: storeProvider,
                runtimeProvider: provider,
                assetsProvider: { mutableAssets.current },
                nativeSearchFactory: nativeSearchFactory,
                advertisedNativeSearchBackends: advertisedNativeSearchBackends,
                governor: governor,
                resourceCoordinator: resourceCoordinator,
                allowsDeveloperModels: allowsDeveloperModels,
                featureAvailability: featureAvailability,
                indexingCapacityProfile: indexingCapacityProfile,
                suggestionCache: suggestionCacheEnabled
                    ? MLSearchSuggestionCache(layout: layout, accountIdentifier: "fixture", cipher: SuggestionCipher())
                    : nil
            ),
            configuration: .init(
                indexRetryDelay: retryDelay,
                closedGateRecheckDelay: closedGateRecheckDelay,
                catalogRefreshInterval: catalogRefreshInterval
            )
        )
        return Harness(
            lifecycle: lifecycle,
            layout: layout,
            stateStore: stateStore,
            transport: transport,
            provider: provider,
            storeProvider: storeProvider,
            assets: mutableAssets,
            governor: governor,
            resourceCoordinator: resourceCoordinator
        )
    }

    /// Polls a condition for a wall-clock budget. The default is generous on purpose: a shared CI runner
    /// needs longer for the same indexing work than a developer Mac, and a short budget turns a slow machine
    /// into a red build. A wrong condition still fails; it only fails later.
    @discardableResult
    private func waitUntil(
        timeout: Duration = .seconds(30),
        _ predicate: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }

    private func waitForCompleteIndex(_ harness: Harness, total: Int) async -> Bool {
        await waitUntil {
            let snapshot = await harness.lifecycle.currentSnapshot()
            if case .ready(let coverage) = snapshot.phase {
                return coverage.isComplete && coverage.total == total
            }
            return false
        }
    }

    private final class PhaseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [MLSmartSearchPhase] = []

        func append(_ phase: MLSmartSearchPhase) { lock.withLock { storage.append(phase) } }
        func reset() { lock.withLock { storage.removeAll() } }
        var isEmpty: Bool { lock.withLock { storage.isEmpty } }
        var sawIndexing: Bool {
            lock.withLock {
                storage.contains { phase in
                    if case .indexing = phase { return true }
                    return false
                }
            }
        }
        func saw(_ phase: MLSmartSearchPhase) -> Bool {
            lock.withLock { storage.contains(phase) }
        }
    }

    private actor BlockingNativeSearchFactory {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var started = false

        /// Only the first call blocks, so a second native preparation fails assertions instead of hanging.
        func make() async -> (any MLNativeSearchServing)? {
            guard !started else { return nil }
            started = true
            await withCheckedContinuation { continuation = $0 }
            return nil
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    @Test func unavailableFeatureNeverStartsOrEnables() async throws {
        let payload = Data("model".utf8)
        let (entry, url) = downloadableEntry(id: "model", payload: payload)
        let harness = try makeHarness(
            catalog: .init(entries: [entry]), payloads: [url: payload], assets: [uid("a")],
            featureAvailability: .unavailable
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.loadModelChoices()
        await harness.lifecycle.enable(with: entry.id)
        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(!snapshot.isSupported)
        #expect(snapshot.phase == .disabled)
        #expect(!snapshot.isEnabled)
        #expect(harness.provider.builtCount == 0)
        #expect(harness.transport.downloadCount == 0)
    }

    @Test func modelChoicesLoadWhileOffWithoutStoringOrDownloadingAnything() async throws {
        let payloadA = Data("model-a".utf8)
        let payloadB = Data("model-b".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payloadA)
        let (entryB, urlB) = downloadableEntry(id: "model-b", payload: payloadB)
        let remote = MLModelCatalog(entries: [entryA, entryB])
        let catalogProvider = RecordingCatalogProvider(remote)
        let harness = try makeHarness(
            catalog: remote,
            payloads: [urlA: payloadA, urlB: payloadB],
            assets: [uid("asset")],
            catalogProvider: catalogProvider
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.loadModelChoices()
        let choosing = await harness.lifecycle.currentSnapshot()
        #expect(choosing.phase == .disabled)
        #expect(!choosing.isEnabled)
        #expect(choosing.selectedModelID == nil)
        #expect(choosing.availableModels.map(\.id) == [entryA.id, entryB.id])
        #expect(await catalogProvider.requestCount == 1)
        #expect(harness.transport.downloadCount == 0)
        #expect(try harness.stateStore.load() == nil, "choosing a model stores nothing")

        // A second request reuses the loaded catalog.
        await harness.lifecycle.loadModelChoices()
        #expect(await catalogProvider.requestCount == 1)

        await harness.lifecycle.enable(with: entryA.id)
        let stored = try #require(try harness.stateStore.load())
        #expect(stored.isEnabled)
        #expect(stored.selectedModelID == entryA.id)
        #expect(await waitForCompleteIndex(harness, total: 1))
        #expect(await harness.lifecycle.currentSnapshot().selectedModelID == entryA.id)
    }

    @Test func failedModelListWhileOffIsRetryableAndStoresNothing() async throws {
        let payload = Data("model".utf8)
        let (entry, url) = downloadableEntry(id: "model", payload: payload)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: []),
            payloads: [url: payload],
            assets: [uid("asset")],
            catalogProvider: FailingOnceCatalogProvider(MLModelCatalog(entries: [entry]))
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.loadModelChoices()
        let failed = await harness.lifecycle.currentSnapshot()
        #expect(!failed.isEnabled)
        guard case .failed(let failure) = failed.phase else {
            Issue.record("a failed model list must stay visible while the person chooses")
            return
        }
        #expect(failure.kind == .catalog && failure.isRetryable)
        #expect(MLSmartSearchModelPresentation(snapshot: failed).canRetry)

        await harness.lifecycle.retry()
        let loaded = await harness.lifecycle.currentSnapshot()
        #expect(loaded.phase == .disabled)
        #expect(loaded.availableModels.map(\.id) == [entry.id])
        #expect(try harness.stateStore.load() == nil)
        #expect(harness.transport.downloadCount == 0)
    }

    @Test func switchingOnStartsTheRecommendedModelWithoutAChoice() async throws {
        let small = Data("small".utf8)
        let large = Data("the-larger-model".utf8)
        let (smallEntry, smallURL) = downloadableEntry(id: "small", payload: small)
        let (largeEntry, largeURL) = downloadableEntry(id: "large", payload: large)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: []),
            payloads: [smallURL: small, largeURL: large],
            assets: [uid("asset")],
            catalogProvider: RecordingCatalogProvider(MLModelCatalog(entries: [largeEntry, smallEntry]))
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        let accepted = await harness.lifecycle.enableRecommended(preferredLanguages: ["en-US"], intent: 1)
        #expect(accepted)
        await harness.lifecycle.awaitRecommendedStart()

        let stored = try #require(try harness.stateStore.load())
        #expect(stored.isEnabled)
        #expect(stored.selectedModelID == smallEntry.id, "English speakers get the smallest model, unasked")
        #expect(await waitForCompleteIndex(harness, total: 1))
        #expect(harness.transport.downloadCount == 1)
        #expect(!(await harness.lifecycle.currentSnapshot().isStartPending))
    }

    @Test func aFailedModelListResumesTheSwitchOnWithRetry() async throws {
        let payload = Data("model".utf8)
        let (entry, url) = downloadableEntry(id: "model", payload: payload)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: []),
            payloads: [url: payload],
            assets: [uid("asset")],
            catalogProvider: FailingOnceCatalogProvider(MLModelCatalog(entries: [entry]))
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enableRecommended(preferredLanguages: ["de-AT"], intent: 1)
        await harness.lifecycle.awaitRecommendedStart()
        let failed = await harness.lifecycle.currentSnapshot()
        #expect(!failed.isEnabled)
        #expect(failed.isStartPending, "the switch stays on while the model list waits for Retry")
        #expect(MLSmartSearchModelPresentation(snapshot: failed).canRetry)
        #expect(try harness.stateStore.load() == nil)

        await harness.lifecycle.retry()

        #expect(try harness.stateStore.load()?.selectedModelID == entry.id)
        #expect(await waitForCompleteIndex(harness, total: 1))
    }

    @Test func turningOffBeforeTheModelListArrivesStartsNothing() async throws {
        let payload = Data("model".utf8)
        let (entry, url) = downloadableEntry(id: "model", payload: payload)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: []),
            payloads: [url: payload],
            assets: [uid("asset")],
            catalogProvider: FailingOnceCatalogProvider(MLModelCatalog(entries: [entry]))
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enableRecommended(preferredLanguages: ["en"], intent: 1)
        await harness.lifecycle.awaitRecommendedStart()
        await harness.lifecycle.cancelRecommendedEnable(intent: 2)
        await harness.lifecycle.retry()
        // A switch-on that reaches the actor after the later switch-off is older and changes nothing.
        let late = await harness.lifecycle.enableRecommended(preferredLanguages: ["en"], intent: 1)

        #expect(!late)
        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(!snapshot.isEnabled)
        #expect(!snapshot.isStartPending)
        #expect(snapshot.phase == .disabled)
        #expect(try harness.stateStore.load() == nil)
        #expect(harness.transport.downloadCount == 0)
    }

    @Test func choosingAnotherModelWhileTheFirstDownloadsStopsItAndStartsTheChoice() async throws {
        let small = Data("small".utf8)
        let large = Data("the-larger-model".utf8)
        let (smallEntry, smallURL) = downloadableEntry(id: "small", payload: small)
        let (largeEntry, largeURL) = downloadableEntry(id: "large", payload: large)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [smallEntry, largeEntry]),
            payloads: [smallURL: small, largeURL: large],
            assets: [uid("asset")]
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        let transport = harness.transport
        transport.blockNextDownload()

        await harness.lifecycle.start()
        await harness.lifecycle.enableRecommended(preferredLanguages: ["en"], intent: 1)
        #expect(await waitUntil { transport.isBlocked })
        let downloading = await harness.lifecycle.currentSnapshot()
        #expect(downloading.allowsModelChoice, "the first download must not lock the model choice")
        #expect(!downloading.hasActivatedModel)

        await harness.lifecycle.select(largeEntry.id)
        await harness.lifecycle.awaitRecommendedStart()
        #expect(transport.downloadCount == 1, "the first model's download stops; only the choice downloads")

        #expect(await waitForCompleteIndex(harness, total: 1))
        let ready = await harness.lifecycle.currentSnapshot()
        #expect(ready.selectedModelID == largeEntry.id)
        #expect(ready.hasActivatedModel)
        #expect(try harness.stateStore.load()?.selectedModelID == largeEntry.id)
        #expect(!FileManager.default.fileExists(atPath: harness.layout.modelDirectory(for: smallEntry.id).path))
    }

    @Test(arguments: [false, true])
    func interruptedInstallRecoversAtColdStartWithoutReset(incomplete: Bool) async throws {
        let payload = Data("cold-start-staging".utf8)
        let (entry, url) = downloadableEntry(id: "cold-staging", payload: payload)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]), payloads: [url: payload], assets: [uid("asset")])
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        _ = try MLInterruptedInstallFixture.write(entry: entry, layout: harness.layout, payloads: [url: payload])
        let staging = harness.layout.stagingDirectory(for: entry.id, revision: "rev1")
        if incomplete {
            try payload.prefix(3).write(to: staging.appendingPathComponent("Model.mlmodelc/weights.bin"))
        }
        try harness.stateStore.save(MLSmartSearchPersistentState(isEnabled: true, selectedModelID: entry.id))
        #expect(harness.provider.attemptCount == 0)

        await harness.lifecycle.start()

        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.isEnabled)
        #expect(snapshot.selectedModelID == entry.id)
        #expect(snapshot.hasActivatedModel)
        guard snapshot.hasActivatedModel else {
            await harness.lifecycle.shutdown()
            return
        }
        #expect(!MLSmartSearchModelPresentation(snapshot: snapshot).canRetry)
        #expect(harness.provider.builtCount == 1)
        #expect(harness.transport.downloadCount == (incomplete ? 1 : 0))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(await waitForCompleteIndex(harness, total: 1))
        #expect(!(try await harness.lifecycle.search("anything", limit: 3)).isEmpty)
        await harness.lifecycle.shutdown()
    }

    @Test(arguments: [false, true])
    func interruptedInstallRecoversOnRetryWithoutReset(incomplete: Bool) async throws {
        let payload = Data("retry-staging".utf8)
        let (entry, url) = downloadableEntry(id: "retry-staging", payload: payload)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]), payloads: [url: payload], assets: [uid("asset")],
            transportOverride: ScriptedTransport(
                payloads: [url: payload], failFirst: [url: 1], failure: MLModelInstallError.installRecordUnreadable))
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entry.id)
        let failed = await harness.lifecycle.currentSnapshot()
        guard case .failed(let failure) = failed.phase else {
            Issue.record("the first transfer must fail")
            await harness.lifecycle.shutdown()
            return
        }
        #expect(failure.kind == .installation)
        #expect(failure.isRetryable)
        #expect(MLSmartSearchModelPresentation(snapshot: failed).canRetry)
        #expect(harness.provider.attemptCount == 0, "an incomplete installation never reaches the runtime")
        _ = try MLInterruptedInstallFixture.write(entry: entry, layout: harness.layout, payloads: [url: payload])
        let staging = harness.layout.stagingDirectory(for: entry.id, revision: "rev1")
        if incomplete {
            try payload.prefix(3).write(to: staging.appendingPathComponent("Model.mlmodelc/weights.bin"))
        }

        await harness.lifecycle.retry()

        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.isEnabled)
        #expect(snapshot.hasActivatedModel)
        guard snapshot.hasActivatedModel else {
            await harness.lifecycle.shutdown()
            return
        }
        #expect(!MLSmartSearchModelPresentation(snapshot: snapshot).canRetry)
        #expect(harness.provider.builtCount == 1)
        #expect(harness.transport.downloadCount == (incomplete ? 2 : 1))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(await waitForCompleteIndex(harness, total: 1))
        #expect(!(try await harness.lifecycle.search("anything", limit: 3)).isEmpty)
        await harness.lifecycle.shutdown()
    }

    @Test func aModelChosenDuringTheFirstDownloadSurvivesAFailedDownloadAndARelaunch() async throws {
        let small = Data("small".utf8)
        let large = Data("the-larger-model".utf8)
        let (smallEntry, smallURL) = downloadableEntry(id: "small", payload: small)
        let (largeEntry, largeURL) = downloadableEntry(id: "large", payload: large)
        let catalog = MLModelCatalog(entries: [smallEntry, largeEntry])
        let first = try makeHarness(
            catalog: catalog,
            payloads: [smallURL: small, largeURL: large],
            assets: [uid("asset")],
            failFirst: [largeURL: 1]
        )
        defer { try? FileManager.default.removeItem(at: first.layout.rootDirectory) }
        first.transport.blockNextDownload()

        await first.lifecycle.start()
        await first.lifecycle.enableRecommended(preferredLanguages: ["en"], intent: 1)
        #expect(await waitUntil { first.transport.isBlocked })
        await first.lifecycle.select(largeEntry.id)
        await first.lifecycle.awaitRecommendedStart()

        // The choice's download failed; the choice itself is stored and shown, not the stopped first model.
        let failed = await first.lifecycle.currentSnapshot()
        #expect(failed.selectedModelID == largeEntry.id)
        #expect(try first.stateStore.load()?.selectedModelID == largeEntry.id)
        await first.lifecycle.shutdown()

        let second = try makeHarness(
            catalog: catalog,
            payloads: [smallURL: small, largeURL: large],
            assets: [uid("asset")],
            root: first.layout.rootDirectory,
            stateStoreOverride: first.stateStore,
            storeProviderOverride: first.storeProvider
        )
        await second.lifecycle.start()

        #expect(await waitForCompleteIndex(second, total: 1))
        #expect(await second.lifecycle.currentSnapshot().selectedModelID == largeEntry.id)
    }

    @Test func aRetiredModelKeepsWorkingAfterARelaunchButIsNeverChosenAgain() async throws {
        let payloadA = Data("model-a".utf8)
        let payloadB = Data("model-b".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payloadA)
        let (entryB, urlB) = downloadableEntry(id: "model-b", payload: payloadB)
        let payloads = [urlA: payloadA, urlB: payloadB]
        let first = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA, entryB]),
            payloads: payloads,
            assets: [uid("asset")],
            allowsDeveloperModels: false
        )
        defer { try? FileManager.default.removeItem(at: first.layout.rootDirectory) }
        await first.lifecycle.start()
        await first.lifecycle.enable(with: entryA.id)
        #expect(await waitForCompleteIndex(first, total: 1))
        await first.lifecycle.shutdown()

        // The next catalog retires model A. The person who uses it keeps search after the relaunch.
        let second = try makeHarness(
            catalog: MLModelCatalog(entries: [retired(entryA), entryB]),
            payloads: payloads,
            assets: [uid("asset")],
            allowsDeveloperModels: false,
            root: first.layout.rootDirectory,
            stateStoreOverride: first.stateStore,
            storeProviderOverride: first.storeProvider
        )
        await second.lifecycle.start()
        #expect(await waitForCompleteIndex(second, total: 1))
        let kept = await second.lifecycle.currentSnapshot()
        #expect(kept.selectedModelID == entryA.id)
        #expect(kept.availableModels.map(\.id) == [entryA.id, entryB.id], "the current choice stays visible")
        #expect(second.transport.downloadCount == 0, "the relaunch downloads nothing")

        // Moving to another model works; moving back to the retired one does not.
        await second.lifecycle.select(entryB.id)
        #expect(await waitForCompleteIndex(second, total: 1))
        #expect(await second.lifecycle.currentSnapshot().availableModels.map(\.id) == [entryB.id])
        await second.lifecycle.select(entryA.id)
        #expect(await second.lifecycle.currentSnapshot().selectedModelID == entryB.id)
        await second.lifecycle.shutdown()
    }

    @Test func aCatalogRefreshThatRetiresTheActiveModelKeepsItActive() async throws {
        let payloadA = Data("model-a".utf8)
        let payloadB = Data("model-b".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payloadA)
        let (entryB, urlB) = downloadableEntry(id: "model-b", payload: payloadB)
        let catalogProvider = RecordingCatalogProvider(MLModelCatalog(entries: [entryA, entryB]))
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA, entryB]),
            payloads: [urlA: payloadA, urlB: payloadB],
            assets: [uid("asset")],
            allowsDeveloperModels: false,
            catalogProvider: catalogProvider,
            catalogRefreshInterval: .zero
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        #expect(await waitForCompleteIndex(harness, total: 1))
        let sessionsBefore = harness.provider.builtCount

        await catalogProvider.replace(MLModelCatalog(entries: [retired(entryA), entryB]))
        await harness.lifecycle.noteConditionsChanged()

        #expect(
            await waitUntil {
                await harness.lifecycle.currentSnapshot().availableModels.contains {
                    $0.id == entryA.id && $0.isRetired
                }
            })
        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.selectedModelID == entryA.id)
        guard case .ready = snapshot.phase else {
            Issue.record("search must stay ready, not ask for a new model: \(snapshot.phase)")
            return
        }
        #expect(harness.provider.builtCount == sessionsBefore, "the active model is neither reloaded nor dropped")
        await harness.lifecycle.shutdown()
    }

    @Test func aSupersededSwitchOnCannotOverwriteTheNewerStateWithItsCatalogFailure() async throws {
        let payload = Data("model".utf8)
        let (entry, url) = downloadableEntry(id: "model", payload: payload)
        let catalogProvider = GatedFirstCatalogProvider(MLModelCatalog(entries: [entry]))
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: []),
            payloads: [url: payload],
            assets: [uid("asset")],
            catalogProvider: catalogProvider
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        // On, off, on: the first request hangs until the person turned the switch on again.
        await harness.lifecycle.enableRecommended(preferredLanguages: ["en"], intent: 1)
        #expect(await waitUntil { await catalogProvider.isWaiting })
        #expect(await harness.lifecycle.currentSnapshot().isStartPending)
        await harness.lifecycle.cancelRecommendedEnable(intent: 2)
        await harness.lifecycle.enableRecommended(preferredLanguages: ["en"], intent: 3)
        await harness.lifecycle.awaitRecommendedStart()
        #expect(await waitForCompleteIndex(harness, total: 1))

        await catalogProvider.failWaitingRequest()
        try await Task.sleep(for: .milliseconds(50))
        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.isEnabled)
        if case .failed = snapshot.phase {
            Issue.record("a superseded catalog failure must not replace the ready state")
        }
        #expect(snapshot.startIntent == 3)
    }

    @Test func aSwitchOnResumedByRetryStopsWhenTheSwitchTurnsOff() async throws {
        let payload = Data("model".utf8)
        let (entry, url) = downloadableEntry(id: "model", payload: payload)
        let catalogProvider = ScriptedCatalogProvider(MLModelCatalog(entries: [entry]), script: [.fail, .hold])
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: []),
            payloads: [url: payload],
            assets: [uid("asset")],
            catalogProvider: catalogProvider
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enableRecommended(preferredLanguages: ["en"], intent: 1)
        await harness.lifecycle.awaitRecommendedStart()
        let retry = Task { await harness.lifecycle.retry() }
        #expect(await waitUntil { await catalogProvider.isHolding })

        // Off, then on again: the new start loads the list and enables Smart Search.
        await harness.lifecycle.cancelRecommendedEnable(intent: 2)
        await harness.lifecycle.enableRecommended(preferredLanguages: ["en"], intent: 3)
        await harness.lifecycle.awaitRecommendedStart()
        #expect(await waitForCompleteIndex(harness, total: 1))

        // The request that Retry started fails late; it belongs to a stopped start and reports nothing.
        await catalogProvider.failHeldRequest()
        await retry.value
        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.isEnabled)
        if case .failed = snapshot.phase {
            Issue.record("a stopped start's late catalog failure must not replace the ready state")
        }
    }

    @Test func aRefusedSwitchOnStillReportsItsIntent() async throws {
        let harness = try makeHarness(catalog: MLModelCatalog(entries: []), payloads: [:], assets: [])
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        // Not started yet: refused, but the snapshot carries the intent so the switch can settle.
        let accepted = await harness.lifecycle.enableRecommended(preferredLanguages: ["en"], intent: 4)

        #expect(!accepted)
        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.startIntent == 4)
        #expect(!snapshot.isStartPending)
    }

    @Test func aChoiceWaitsUntilAFailedSwitchCleanupIsRetried() async throws {
        let payloadA = Data("model-a".utf8)
        let payloadB = Data("model-b".utf8)
        let payloadC = Data("model-c".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payloadA)
        let (entryB, urlB) = downloadableEntry(id: "model-b", payload: payloadB)
        let (entryC, urlC) = downloadableEntry(id: "model-c", payload: payloadC)
        let rootDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let flaky = FlakyStateStore(layout: MLModelInstallLayout(rootDirectory: rootDir))
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA, entryB, entryC]),
            payloads: [urlA: payloadA, urlB: payloadB, urlC: payloadC],
            assets: [uid("asset")],
            root: rootDir,
            stateStoreOverride: flaky
        )
        defer { try? FileManager.default.removeItem(at: rootDir) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        #expect(await waitForCompleteIndex(harness, total: 1))
        // The journal to B is written, but committing its cleanup fails: the switch stays journaled.
        flaky.setFailing(where: { $0.pendingOperation == nil && $0.selectedModelID == entryB.id })
        await harness.lifecycle.select(entryB.id)
        #expect(try flaky.load()?.pendingOperation == .switchModel(from: entryA.id, to: entryB.id))

        await harness.lifecycle.select(entryC.id)

        let stored = try #require(try flaky.load())
        #expect(stored.pendingOperation == .switchModel(from: entryA.id, to: entryB.id), "the journal stays intact")
        #expect(stored.selectedModelID == entryB.id)
        #expect(harness.transport.downloadCount == 2, "the choice waits instead of downloading")

        // A developer install waits too, so the failure and its Retry stay visible.
        let artifact = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-dev-artifact-\(UUID().uuidString)", isDirectory: true)
        let model = artifact.appendingPathComponent("Test.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: model.appendingPathComponent("model.bin"))
        defer { try? FileManager.default.removeItem(at: artifact) }
        await harness.lifecycle.installDeveloperModel(from: artifact, for: entryC.id)
        guard case .failed(let failure) = await harness.lifecycle.currentSnapshot().phase else {
            Issue.record("the failed switch must stay visible")
            return
        }
        #expect(failure.isRetryable)
        #expect(!FileManager.default.fileExists(atPath: harness.layout.modelDirectory(for: entryC.id).path))
    }

    @Test func aSecondRetryTapStartsNoSecondSwitchOn() async throws {
        let payload = Data("model".utf8)
        let (entry, url) = downloadableEntry(id: "model", payload: payload)
        let catalogProvider = ScriptedCatalogProvider(MLModelCatalog(entries: [entry]), script: [.fail, .hold, .hold])
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: []),
            payloads: [url: payload],
            assets: [uid("asset")],
            catalogProvider: catalogProvider
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enableRecommended(preferredLanguages: ["en"], intent: 1)
        await harness.lifecycle.awaitRecommendedStart()
        let first = Task { await harness.lifecycle.retry() }
        #expect(await waitUntil { await catalogProvider.isHolding })
        // The first Retry shows the list loading, so a second tap finds no failure to retry.
        #expect(await harness.lifecycle.currentSnapshot().phase == .loadingCatalog)
        await harness.lifecycle.retry()
        #expect(await catalogProvider.requestCount == 2)

        await harness.lifecycle.cancelRecommendedEnable(intent: 2)
        await catalogProvider.failHeldRequest()
        await first.value

        #expect(await catalogProvider.requestCount == 2, "one list request per Retry, not per tap")
        #expect(await harness.lifecycle.currentSnapshot().phase == .disabled)
    }

    @Test func enablingAgainSwitchesToTheChosenModel() async throws {
        let payloadA = Data("model-a".utf8)
        let payloadB = Data("model-b".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payloadA)
        let (entryB, urlB) = downloadableEntry(id: "model-b", payload: payloadB)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA, entryB]),
            payloads: [urlA: payloadA, urlB: payloadB],
            assets: [uid("asset")]
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        #expect(await waitForCompleteIndex(harness, total: 1))

        await harness.lifecycle.enable(with: entryB.id)
        #expect(await waitUntil { await harness.lifecycle.currentSnapshot().selectedModelID == entryB.id })
        #expect(await waitForCompleteIndex(harness, total: 1))
        #expect(harness.storeProvider.store.count(for: entryA.descriptor) == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.layout.modelDirectory(for: entryA.id).path))
    }

    @Test func modelThatDoesNotFitReportsTheSpaceAndRetriesAfterSpaceIsFreed() async throws {
        let payload = Data("model".utf8)
        let (entry, url) = downloadableEntry(id: "model", payload: payload)
        let nativeOnly = uid("asset")
        let nativeSearch = RecordingNativeSearch(results: [nativeOnly])
        let freeSpace = FreeSpace(0)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]),
            payloads: [url: payload],
            assets: [nativeOnly],
            nativeSearch: nativeSearch,
            freeSpace: freeSpace
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entry.id)
        let required = Int64(payload.count) + MLModelInstaller.storageReserveBytes
        #expect(
            await waitUntil {
                guard case .failed(let failure) = await harness.lifecycle.currentSnapshot().phase else { return false }
                return failure.kind == .insufficientStorage && failure.isRetryable && failure.requiredBytes == required
            })
        #expect(harness.transport.downloadCount == 0)
        // Text search keeps working while the model waits for space.
        #expect(await waitUntil { await harness.lifecycle.currentSnapshot().isSearchAvailable })
        #expect(try await harness.lifecycle.searchUIDs("receipt", scope: .text, limit: 5) == [nativeOnly])

        freeSpace.value = required
        await harness.lifecycle.retry()
        #expect(await waitForCompleteIndex(harness, total: 1))
    }

    @Test func nativeIndexingRunsWhileTheModelDownloads() async throws {
        let payload = Data("model".utf8)
        let (entry, url) = downloadableEntry(id: "model", payload: payload)
        let assets = [uid("a"), uid("b")]
        let nativeSearch = RecordingNativeSearch(results: [])
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]),
            payloads: [url: payload],
            assets: assets,
            nativeSearch: nativeSearch
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        let transport = harness.transport
        transport.blockNextDownload()

        await harness.lifecycle.start()
        let enable = Task { await harness.lifecycle.enable(with: entry.id) }
        #expect(await waitUntil { transport.isBlocked })
        #expect(
            await waitUntil { Set(nativeSearch.indexedUIDs) == Set(assets) },
            "text indexing must not wait for the model")

        transport.releaseBlockedDownload()
        await enable.value
        #expect(await waitForCompleteIndex(harness, total: assets.count))
    }

    @Test func enablePublishesBeforeNativeInitializationCompletes() async throws {
        let factory = BlockingNativeSearchFactory()
        let local = localModelEntry()
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [local]),
            payloads: [:],
            assets: [],
            nativeSearchFactoryOverride: { await factory.make() },
            advertisedNativeSearchBackends: [.recognizedText, .documentText]
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        let phases = PhaseRecorder()
        let observation = Task {
            for await snapshot in await harness.lifecycle.snapshots() {
                phases.append(snapshot.phase)
            }
        }
        defer { observation.cancel() }
        #expect(await waitUntil { !phases.isEmpty })
        phases.reset()

        let enable = Task { await harness.lifecycle.enable(with: local.id) }
        #expect(await waitUntil { await factory.started })
        #expect(await waitUntil(timeout: .milliseconds(250)) { phases.saw(.notInstalled(downloadable: false)) })
        #expect(await harness.lifecycle.availableSearchScopes() == [.all, .text])

        await factory.release()
        await enable.value
        #expect(await harness.lifecycle.currentSnapshot().isEnabled)
    }

    @Test func enforcedCoordinatorDefersNativeModelLoadingUntilStableRecovery() async throws {
        let runtimeState = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(thermalLevel: .critical))
        let coordinator = LibraryResourceCoordinator(
            runtimeState: runtimeState,
            recoveryDelay: .milliseconds(20)
        )
        await coordinator.startObserving()
        let factory = BlockingNativeSearchFactory()
        let local = localModelEntry()
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [local]),
            payloads: [:],
            assets: [],
            nativeSearchFactoryOverride: { await factory.make() },
            resourceCoordinator: coordinator
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        let enable = Task { await harness.lifecycle.enable(with: local.id) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!(await factory.started))
        #expect((await coordinator.metrics()).policyPauses == 1)

        runtimeState.update { $0.thermalLevel = .nominal }
        #expect(await waitUntil { await factory.started })
        await factory.release()
        await enable.value
        // A native runtime that could not be created is tried again when the model activates. Every permit
        // still comes back.
        let metrics = await coordinator.metrics()
        #expect(metrics.permitsAcquired >= 1)
        #expect(metrics.permitsReleased == metrics.permitsAcquired)
    }

    @Test func enforcedCoordinatorOwnsSemanticLoadIndexAndInteractiveInference() async throws {
        let payload = Data("model".utf8)
        let (entry, url) = downloadableEntry(id: "coordinated-model", payload: payload)
        let coordinator = LibraryResourceCoordinator(runtimeState: LibraryRuntimeState())
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]),
            payloads: [url: payload],
            assets: [uid("asset")],
            resourceCoordinator: coordinator
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entry.id)
        #expect(await waitForCompleteIndex(harness, total: 1))
        let beforeSearch = await coordinator.metrics()
        #expect(beforeSearch.permitsAcquired >= 2)
        #expect(beforeSearch.permitsAcquired == beforeSearch.permitsReleased)

        _ = try await harness.lifecycle.search("query", limit: 1)
        let afterSearch = await coordinator.metrics()
        #expect(afterSearch.permitsAcquired == beforeSearch.permitsAcquired + 1)
        #expect(afterSearch.permitsReleased == afterSearch.permitsAcquired)
    }

    @Test func nativeIndexServesSearchWhileTheModelIsNotInstalled() async throws {
        let local = localModelEntry()
        let assets = [uid("a"), uid("b"), uid("c")]
        let nativeOnly = assets[0]
        let nativeSearch = RecordingNativeSearch(results: [nativeOnly])
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [local]),
            payloads: [:],
            assets: assets,
            nativeSearch: nativeSearch
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: local.id)

        #expect(await waitUntil { Set(nativeSearch.indexedUIDs) == Set(assets) })
        // The aggregate state publishes after the native backend records its last item.
        #expect(await waitUntil { await harness.lifecycle.currentSnapshot().isSearchAvailable })
        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.isEnabled)
        #expect(snapshot.selectedModelID == local.id)
        #expect(snapshot.phase == .notInstalled(downloadable: false))
        #expect(snapshot.isSearchAvailable)
        #expect(harness.transport.downloadCount == 0)
        if case .ready(let progress) = snapshot.indexingState {
            #expect(progress.isComplete)
        } else {
            Issue.record("native-only indexing must reach the aggregate ready state")
        }
        #expect(try await harness.lifecycle.searchUIDs("receipt", scope: .text, limit: 5) == [nativeOnly])
    }

    @Test func completedNativeBackendRerunsOnlyForLibraryChanges() async throws {
        let nativeSearch = RecordingNativeSearch(results: [])
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [localModelEntry()]),
            payloads: [:],
            assets: [uid("a")],
            nativeSearch: nativeSearch
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: localModelEntry().id)
        #expect(await waitUntil { nativeSearch.indexCount == 1 })

        await harness.lifecycle.noteConditionsChanged()
        try await Task.sleep(for: .milliseconds(100))
        #expect(nativeSearch.indexCount == 1)

        harness.assets.set([uid("a"), uid("b")])
        await harness.lifecycle.noteLibraryChanged()
        #expect(await waitUntil { nativeSearch.indexCount == 2 && nativeSearch.indexedUIDs.count == 2 })
    }

    @Test func completedNativeBackendIndexesHydratingScopeWithoutReconcilingStoredRows() async throws {
        let existing = uid("existing")
        let nativeSearch = RecordingNativeSearch(results: [], initiallyIndexed: [existing])
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: []),
            payloads: [:],
            assets: [existing],
            nativeSearch: nativeSearch
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        harness.assets.beginHydration()
        try harness.stateStore.save(MLSmartSearchPersistentState(isEnabled: true))

        await harness.lifecycle.start()
        try await Task.sleep(for: .milliseconds(100))

        #expect(nativeSearch.indexCount == 1)
        #expect(nativeSearch.indexedUIDs == [existing])

        harness.assets.set([existing])
        await harness.lifecycle.noteLibraryChanged()
        #expect(
            await waitUntil {
                nativeSearch.indexCount == 2 && nativeSearch.indexedUIDs == [existing]
            })
    }

    @Test func semanticDownloadFailureDoesNotDisableCompletedNativeSearch() async throws {
        let payload = Data("model".utf8)
        let (entry, url) = downloadableEntry(id: "model", payload: payload)
        let nativeOnly = uid("asset")
        let nativeSearch = RecordingNativeSearch(results: [nativeOnly])
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]),
            payloads: [url: payload],
            assets: [uid("asset")],
            failFirst: [url: 1],
            nativeSearch: nativeSearch
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entry.id)
        #expect(
            await waitUntil {
                guard nativeSearch.indexedUIDs.count == 1 else { return false }
                return await harness.lifecycle.currentSnapshot().isSearchAvailable
            })
        #expect(
            await waitUntil {
                if case .failed(let failure) = await harness.lifecycle.currentSnapshot().phase {
                    return failure.kind == .download
                }
                return false
            })

        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.isSearchAvailable)
        #expect(try await harness.lifecycle.searchUIDs("receipt", scope: .text, limit: 5) == [nativeOnly])
    }

    @Test func persistedSemanticSelectionDoesNotGateNativeSearchWhenCatalogRefreshFails() async throws {
        let payload = Data("model".utf8)
        let (entry, url) = downloadableEntry(id: "model", payload: payload)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-lifecycle-tests-\(UUID().uuidString)", isDirectory: true)
        let layout = MLModelInstallLayout(rootDirectory: root)
        let stateStore = FileMLSmartSearchStateStore(layout: layout)
        try stateStore.save(
            MLSmartSearchPersistentState(
                isEnabled: true,
                selectedModelID: entry.id
            ))
        let nativeOnly = uid("asset")
        let nativeSearch = RecordingNativeSearch(results: [nativeOnly])
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]),
            payloads: [url: payload],
            assets: [uid("asset")],
            root: root,
            stateStoreOverride: stateStore,
            catalogProvider: FailingCatalogProvider(),
            nativeSearch: nativeSearch
        )
        defer { try? FileManager.default.removeItem(at: root) }

        await harness.lifecycle.start()

        #expect(
            await waitUntil {
                guard nativeSearch.indexedUIDs.count == 1 else { return false }
                return await harness.lifecycle.currentSnapshot().isSearchAvailable
            })
        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.isSearchAvailable)
        if case .failed(let failure) = snapshot.phase {
            #expect(failure.kind == .catalog)
        } else {
            Issue.record("catalog failure must remain visible without disabling native search")
        }
        #expect(try await harness.lifecycle.searchUIDs("receipt", scope: .text, limit: 5) == [nativeOnly])
    }

    @Test func coldStartRecoversVerifiedLocalSemanticModelWhenCatalogRefreshFails() async throws {
        let payload = Data("model".utf8)
        let (entry, url) = downloadableEntry(id: "model", payload: payload)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-lifecycle-local-recovery-\(UUID().uuidString)", isDirectory: true)
        let layout = MLModelInstallLayout(rootDirectory: root)
        let stateStore = FileMLSmartSearchStateStore(layout: layout)
        try stateStore.save(
            MLSmartSearchPersistentState(
                isEnabled: true,
                selectedModelID: entry.id
            ))
        let installTransport = ScriptedTransport(payloads: [url: payload])
        _ = try await MLModelInstaller(layout: layout, transport: installTransport).install(entry) { _ in }

        let assets = [uid("asset")]
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]),
            payloads: [url: payload],
            assets: assets,
            root: root,
            stateStoreOverride: stateStore,
            catalogProvider: FailingCatalogProvider()
        )
        defer { try? FileManager.default.removeItem(at: root) }

        await harness.lifecycle.start()

        #expect(await waitForCompleteIndex(harness, total: assets.count))
        #expect(harness.provider.builtCount == 1)
        #expect(harness.transport.downloadCount == 0)
        #expect(try stateStore.load()?.activatedRevision == "rev1")
    }

    @Test func selectingOptionalModelDownloadsInstallsAndIndexesToCompletion() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let assets = (0..<20).map { uid("asset-\($0)") }
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: assets)
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        #expect(await harness.lifecycle.currentSnapshot().phase == .disabled)

        await harness.lifecycle.enable(with: entryA.id)
        #expect(await waitForCompleteIndex(harness, total: assets.count))

        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.isEnabled)
        #expect(snapshot.selectedModelID == entryA.id)
        #expect(snapshot.isSearchAvailable)
        #expect(snapshot.installedModelBytes == Int64(payload.count))
        #expect(harness.storeProvider.store.count(for: entryA.descriptor) == assets.count)
        // Every asset embedded exactly once.
        #expect(harness.provider.embedder.totalCalls == assets.count)

        // Search returns epoch-consistent results.
        let results = try await harness.lifecycle.search("anything", limit: 5)
        #expect(results.descriptor == entryA.descriptor)
        #expect(!results.isEmpty)
    }

    @Test func backgroundExecutionWindowIndexesWithReducedCacheBudget() async throws {
        let runtimeState = LibraryRuntimeState(
            initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted))
        await MainActor.run {
            MemoryPressureGovernor(runtimeState: runtimeState).update(MemoryConditions(isBackgrounded: true))
        }
        let coordinator = LibraryResourceCoordinator(runtimeState: runtimeState)
        let budget = await coordinator.budget(for: LibraryWorkRequest(workload: .mlIndexing, intent: .automatic))
        try #require(budget.isAdmitted)
        let payload = Data("background-model".utf8)
        let (entry, url) = downloadableEntry(id: "background-model", payload: payload)
        let photo = uid("background-photo")
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]), payloads: [url: payload], assets: [photo],
            resourceCoordinator: coordinator
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        await harness.lifecycle.setIndexingExecutionAllowed(false)
        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entry.id)
        #expect(harness.provider.embedder.totalCalls == 0)
        #expect(await harness.lifecycle.performBackgroundCatchUp() == .deferred)

        await harness.lifecycle.setIndexingExecutionAllowed(true)
        #expect(await harness.lifecycle.performBackgroundCatchUp() == .complete)
        #expect(harness.provider.embedder.callCount(photo) == 1)
        #expect(harness.storeProvider.store.count(for: entry.descriptor) == 1)
        #expect(runtimeState.snapshot().memoryBudgetTier == .reduced)
        await harness.lifecycle.shutdown()
        let metrics = await coordinator.metrics()
        #expect(metrics.permitsAcquired > 0)
        #expect(metrics.permitsAcquired == metrics.permitsReleased)
    }

    @Test func executionWindowsReuseOneIndexAndRespectPendingLibraryChanges() async throws {
        let payload = Data("background-model".utf8)
        let (entry, url) = downloadableEntry(id: "background-model", payload: payload)
        let first = uid("first")
        let second = uid("second")
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]), payloads: [url: payload], assets: [first])
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        await harness.lifecycle.setIndexingExecutionAllowed(false)
        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entry.id)

        #expect(harness.provider.embedder.totalCalls == 0)
        #expect(await harness.lifecycle.performBackgroundCatchUp() == .deferred)
        #expect(await harness.lifecycle.currentSnapshot().isEnabled)
        await harness.lifecycle.setIndexingExecutionAllowed(true)
        async let firstWindow = harness.lifecycle.performBackgroundCatchUp()
        async let secondWindow = harness.lifecycle.performBackgroundCatchUp()
        let windows = await (firstWindow, secondWindow)
        #expect(windows.0 == .complete)
        #expect(windows.1 == .complete)
        #expect(harness.provider.embedder.callCount(first) == 1)

        harness.assets.set([first, second])
        await harness.lifecycle.noteLibraryChanged()
        #expect(await harness.lifecycle.performBackgroundCatchUp() == .complete)
        #expect(harness.storeProvider.store.count(for: entry.descriptor) == 2)
        #expect(harness.provider.embedder.callCount(first) == 1)
        #expect(harness.provider.embedder.callCount(second) == 1)
        await harness.lifecycle.shutdown()
    }

    @Test func backgroundCatchUpYieldsToPolicyWithoutDisablingSearch() async throws {
        let payload = Data("background-model".utf8)
        let (entry, url) = downloadableEntry(id: "background-model", payload: payload)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]), payloads: [url: payload], assets: [uid("photo")])
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        harness.governor.set(false)
        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entry.id)
        #expect(await harness.lifecycle.performBackgroundCatchUp() == .deferred)
        #expect(harness.provider.embedder.totalCalls == 0)
        #expect(await harness.lifecycle.currentSnapshot().isEnabled)
        harness.governor.set(true)
        #expect(await harness.lifecycle.performBackgroundCatchUp() == .complete)
        await harness.lifecycle.shutdown()
    }

    @Test func executionReopensTheSelectedModelWhenNativeSearchAlreadyExists() async throws {
        let payload = Data("resume-model".utf8)
        let (entry, url) = downloadableEntry(id: "resume-model", payload: payload)
        let photo = uid("photo")
        let native = RecordingNativeSearch(results: [photo])
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]), payloads: [url: payload], assets: [photo],
            nativeSearchFactoryOverride: { native })
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        await harness.lifecycle.start()
        harness.provider.failNext()
        await harness.lifecycle.enable(with: entry.id)
        #expect(harness.provider.builtCount == 0)
        await harness.lifecycle.setIndexingExecutionAllowed(false)
        await harness.lifecycle.setIndexingExecutionAllowed(true)
        #expect(await harness.lifecycle.performBackgroundCatchUp() == .complete)
        #expect(harness.provider.builtCount == 1)
        #expect(harness.provider.embedder.callCount(photo) == 1)
        #expect(native.shutdownCount == 0)
        await harness.lifecycle.shutdown()
    }

    @Test func cancellingOneBackgroundWaiterDoesNotCancelSharedIndexing() async throws {
        let payload = Data("background-model".utf8)
        let (entry, url) = downloadableEntry(id: "background-model", payload: payload)
        let photo = uid("photo")
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]), payloads: [url: payload], assets: [photo])
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        await harness.provider.embedder.blockNextEmbedding()
        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entry.id)
        await harness.provider.embedder.waitUntilEmbeddingStarted()
        let cancelledWindow = Task { await harness.lifecycle.performBackgroundCatchUp() }
        let survivingWindow = Task { await harness.lifecycle.performBackgroundCatchUp() }
        cancelledWindow.cancel()
        #expect(await cancelledWindow.value == .cancelled)
        await harness.provider.embedder.releaseEmbedding()
        #expect(await survivingWindow.value == .complete)
        #expect(harness.provider.embedder.callCount(photo) == 1)
        await harness.lifecycle.shutdown()
    }

    @Test(arguments: [false, true])
    func closingExecutionJoinsTheQuantumAndResumesWithoutReindexingSettledAssets(
        foregroundDuringDrain: Bool
    ) async throws {
        let payload = Data("background-model".utf8)
        let (entry, url) = downloadableEntry(id: "background-model", payload: payload)
        let first = uid("first")
        let second = uid("second")
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]), payloads: [url: payload], assets: [first])
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entry.id)
        #expect(await harness.lifecycle.performBackgroundCatchUp() == .complete)
        await harness.provider.embedder.blockNextEmbedding()
        harness.assets.set([first, second])
        await harness.lifecycle.noteLibraryChanged()
        await harness.provider.embedder.waitUntilEmbeddingStarted()
        let closing = Task { await harness.lifecycle.setIndexingExecutionAllowed(false) }
        #expect(await waitUntil { harness.provider.embedder.cancellationCount > 0 })
        #expect(harness.storeProvider.store.count(for: entry.descriptor) == 1)
        if foregroundDuringDrain { await harness.lifecycle.setIndexingExecutionAllowed(true) }
        await harness.provider.embedder.releaseEmbedding()
        await closing.value
        if !foregroundDuringDrain {
            #expect(await harness.lifecycle.performBackgroundCatchUp() == .deferred)
            await harness.lifecycle.setIndexingExecutionAllowed(true)
        }
        #expect(await harness.lifecycle.currentSnapshot().isEnabled)
        #expect(await harness.lifecycle.performBackgroundCatchUp() == .complete)
        #expect(harness.storeProvider.store.count(for: entry.descriptor) == 2)
        #expect(harness.provider.embedder.callCount(first) == 1)
        await harness.lifecycle.shutdown()
    }

    @Test func searchBecomesAvailableAfterFirstDurableIndexChunk() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let assets = (0..<80).map { uid("asset-\($0)") }
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: assets
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        harness.provider.embedder.setDelay(.milliseconds(5))

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        #expect(
            await waitUntil {
                let snapshot = await harness.lifecycle.currentSnapshot()
                guard case .indexing = snapshot.phase else { return false }
                return snapshot.isSearchAvailable
            })
        let results = try await harness.lifecycle.search("anything", limit: 3)
        #expect(!results.isEmpty)
    }

    @Test func nativeIndexAndScopedSearchShareTheUniversalLifecycle() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let nativeOnly = uid("native-only")
        let assets = [uid("a"), uid("b"), nativeOnly]
        let nativeSearch = RecordingNativeSearch(results: [nativeOnly])
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: assets,
            nativeSearch: nativeSearch
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        // Keep the native hit behind the semantic hits so this exercises rank interleaving,
        // independently of Swift's randomized hashing.
        harness.provider.embedder.setEmbeddingIndex(0, for: assets[0])
        harness.provider.embedder.setEmbeddingIndex(0, for: assets[1])
        harness.provider.embedder.setEmbeddingIndex(1, for: nativeOnly)

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        #expect(Set(nativeSearch.indexedUIDs) == Set(assets))
        #expect(await harness.lifecycle.availableSearchScopes() == [.all, .text])
        #expect(try await harness.lifecycle.searchUIDs("receipt", scope: .text, limit: 5) == [nativeOnly])

        let semantic = try await harness.lifecycle.searchUIDs("receipt", scope: .semantic, limit: 5)
        let combined = try await harness.lifecycle.searchUIDs("receipt", scope: .all, limit: 5)
        #expect(!semantic.isEmpty)
        #expect(semantic.first != nativeOnly)
        #expect(combined.first == semantic.first)
        #expect(combined.dropFirst().first == nativeOnly)

        await harness.lifecycle.shutdown()
        #expect(nativeSearch.shutdownCount == 1)
    }

    @Test func centralCoordinatorRunsNativeQuantumBeforeSemanticQuantum() async throws {
        final class Events: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String] = []
            func append(_ value: String) { lock.withLock { values.append(value) } }
            var snapshot: [String] { lock.withLock { values } }
        }
        final class Native: MLNativeSearchServing, @unchecked Sendable {
            let events: Events
            init(events: Events) { self.events = events }
            func availableBackends() async -> Set<MLSearchBackend> { [.recognizedText] }
            func index(
                assets: [MLPipelineAssetRevision],
                shouldContinue: @escaping @Sendable () -> Bool,
                observer: MLDerivedPipelineObserver
            ) async -> MLDerivedPipelinePassOutcome {
                await indexQuantum(
                    assets: assets,
                    libraryGeneration: 0,
                    allowsDestructiveReconciliation: true,
                    maximumAssets: assets.count,
                    maximumConcurrentAssets: 1,
                    shouldContinue: shouldContinue,
                    observer: observer
                )
            }
            func indexQuantum(
                assets: [MLPipelineAssetRevision],
                libraryGeneration: UInt64,
                allowsDestructiveReconciliation: Bool,
                maximumAssets: Int,
                maximumConcurrentAssets: Int,
                shouldContinue: @escaping @Sendable () -> Bool,
                observer: MLDerivedPipelineObserver
            ) async -> MLDerivedPipelinePassOutcome {
                events.append("native")
                let progress = MLDerivedPipelineProgress(
                    total: assets.count,
                    completed: assets.count,
                    skipped: 0,
                    permanentFailure: 0,
                    retryPending: 0,
                    generation: libraryGeneration
                )
                observer.report(progress)
                return .init(reason: .drained, progress: progress)
            }
            func search(_ text: String, scope: MLSearchScope, limit: Int) async -> [PhotoUID] { [] }
            func progress() async -> MLDerivedPipelineProgress {
                .init(
                    total: 0,
                    completed: 0,
                    skipped: 0,
                    permanentFailure: 0,
                    retryPending: 0,
                    generation: 0
                )
            }
            func purge() async {}
            func shutdown() async {}
        }
        final class Semantic: MLSmartSearchSession, @unchecked Sendable {
            let descriptor: MLModelDescriptor
            let events: Events
            init(descriptor: MLModelDescriptor, events: Events) {
                self.descriptor = descriptor
                self.events = events
            }
            func index(_ assets: [PhotoUID], observer: MLIndexPassObserver) async -> MLIndexPassOutcome {
                await indexQuantum(assets, maximumAssets: assets.count, observer: observer)
            }
            func indexQuantum(
                _ assets: [PhotoUID],
                maximumAssets: Int,
                observer: MLIndexPassObserver
            ) async -> MLIndexPassOutcome {
                events.append("semantic")
                let progress = MLIndexProgress(
                    phase: .completed,
                    descriptor: descriptor,
                    totalAssets: assets.count,
                    alreadyIndexed: assets.count
                )
                observer.reportProgressUpdated(progress)
                return .init(
                    report: .init(total: assets.count, skippedAlreadyIndexed: assets.count),
                    ranToCompletion: true,
                    newPermanentFailures: [],
                    progress: progress
                )
            }
            func search(_ text: String, limit: Int) async throws -> MLSearchResults {
                .init(descriptor: descriptor, queryText: text, results: [])
            }
            func releaseMemory() async {}
            func shutdown() async {}
        }

        let payload = Data("model".utf8)
        let (entry, url) = downloadableEntry(id: "ordered", payload: payload)
        let events = Events()
        let native = Native(events: events)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]),
            payloads: [url: payload],
            assets: [uid("1"), uid("2")],
            nativeSearchFactoryOverride: { native }
        )
        harness.provider.sessionOverride = { model in
            Semantic(descriptor: model.entry.descriptor, events: events)
        }
        harness.governor.set(false)
        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entry.id)

        harness.governor.set(true)
        await harness.lifecycle.noteConditionsChanged()
        #expect(await waitUntil { events.snapshot.count >= 2 })
        #expect(Array(events.snapshot.prefix(2)) == ["native", "semantic"])
        await harness.lifecycle.shutdown()
    }

    @Test func sustainedNativeLifecycleRampsOneOneTwoTwoThreeAcrossCleanQuanta() async throws {
        final class Native: MLNativeSearchServing, @unchecked Sendable {
            private let lock = NSLock()
            private var processed = 0
            private var total = 0
            private var observedParallelism: [Int] = []

            func availableBackends() async -> Set<MLSearchBackend> { [.recognizedText] }
            func maximumConcurrentAssets() async -> Int { 3 }
            func index(
                assets: [MLPipelineAssetRevision],
                shouldContinue: @escaping @Sendable () -> Bool,
                observer: MLDerivedPipelineObserver
            ) async -> MLDerivedPipelinePassOutcome {
                await indexQuantum(
                    assets: assets,
                    libraryGeneration: 0,
                    allowsDestructiveReconciliation: true,
                    maximumAssets: assets.count,
                    maximumConcurrentAssets: 1,
                    shouldContinue: shouldContinue,
                    observer: observer
                )
            }
            func indexQuantum(
                assets: [MLPipelineAssetRevision],
                libraryGeneration: UInt64,
                allowsDestructiveReconciliation: Bool,
                maximumAssets: Int,
                maximumConcurrentAssets: Int,
                shouldContinue: @escaping @Sendable () -> Bool,
                observer: MLDerivedPipelineObserver
            ) async -> MLDerivedPipelinePassOutcome {
                guard shouldContinue() else {
                    return .init(reason: .policySuspended, progress: await progress())
                }
                let snapshot = lock.withLock { () -> (Int, Int) in
                    total = assets.count
                    observedParallelism.append(maximumConcurrentAssets)
                    processed = min(total, processed + maximumAssets)
                    return (processed, total)
                }
                let progress = MLDerivedPipelineProgress(
                    total: snapshot.1,
                    completed: snapshot.0,
                    skipped: 0,
                    permanentFailure: 0,
                    retryPending: 0,
                    generation: libraryGeneration
                )
                observer.report(progress)
                return .init(
                    reason: snapshot.0 == snapshot.1 ? .drained : .workQuantumCompleted,
                    progress: progress
                )
            }
            func search(_ text: String, scope: MLSearchScope, limit: Int) async -> [PhotoUID] { [] }
            func progress() async -> MLDerivedPipelineProgress {
                let snapshot = lock.withLock { (processed, total) }
                return .init(
                    total: snapshot.1,
                    completed: snapshot.0,
                    skipped: 0,
                    permanentFailure: 0,
                    retryPending: 0,
                    generation: 0
                )
            }
            func purge() async {}
            func shutdown() async {}
            var parallelism: [Int] { lock.withLock { observedParallelism } }
        }

        let native = Native()
        let assets = (0..<160).map { uid("native-\($0)") }
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [localModelEntry()]),
            payloads: [:],
            assets: assets,
            nativeSearchFactoryOverride: { native },
            advertisedNativeSearchBackends: [.recognizedText],
            indexingCapacityProfile: .sustained
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: localModelEntry().id)
        #expect(await waitUntil { native.parallelism.count >= 5 })
        #expect(Array(native.parallelism.prefix(5)) == [1, 1, 2, 2, 3])

        await harness.lifecycle.shutdown()
    }

    @Test func expiredNativeTimeSliceReentersCoordinatorWithoutRetryDelay() async throws {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var value: UInt64 = 0
            func now() -> UInt64 { lock.withLock { value } }
            func advanceTwoSeconds() { lock.withLock { value += 2_000_000_000 } }
        }
        final class Native: MLNativeSearchServing, @unchecked Sendable {
            private let lock = NSLock()
            private let clock: Clock
            private var processed = 0
            private var total = 0
            private var calls = 0

            init(clock: Clock) { self.clock = clock }
            func availableBackends() async -> Set<MLSearchBackend> { [.recognizedText] }
            func maximumConcurrentAssets() async -> Int { 1 }
            func index(
                assets: [MLPipelineAssetRevision],
                shouldContinue: @escaping @Sendable () -> Bool,
                observer: MLDerivedPipelineObserver
            ) async -> MLDerivedPipelinePassOutcome {
                await indexQuantum(
                    assets: assets,
                    libraryGeneration: 0,
                    allowsDestructiveReconciliation: true,
                    maximumAssets: assets.count,
                    maximumConcurrentAssets: 1,
                    shouldContinue: shouldContinue,
                    observer: observer
                )
            }
            func indexQuantum(
                assets: [MLPipelineAssetRevision],
                libraryGeneration: UInt64,
                allowsDestructiveReconciliation: Bool,
                maximumAssets: Int,
                maximumConcurrentAssets: Int,
                shouldContinue: @escaping @Sendable () -> Bool,
                observer: MLDerivedPipelineObserver
            ) async -> MLDerivedPipelinePassOutcome {
                lock.withLock {
                    total = assets.count
                    calls += 1
                }
                var completedThisQuantum = 0
                while completedThisQuantum < maximumAssets {
                    guard shouldContinue() else {
                        return .init(reason: .policySuspended, progress: await progress())
                    }
                    let didProcess = lock.withLock { () -> Bool in
                        guard processed < total else { return false }
                        processed += 1
                        return true
                    }
                    guard didProcess else { break }
                    completedThisQuantum += 1
                    clock.advanceTwoSeconds()
                }
                let progress = await progress()
                observer.report(progress)
                return .init(
                    reason: progress.isComplete ? .drained : .workQuantumCompleted,
                    progress: progress
                )
            }
            func search(_ text: String, scope: MLSearchScope, limit: Int) async -> [PhotoUID] { [] }
            func progress() async -> MLDerivedPipelineProgress {
                let snapshot = lock.withLock { (processed, total) }
                return .init(
                    total: snapshot.1,
                    completed: snapshot.0,
                    skipped: 0,
                    permanentFailure: 0,
                    retryPending: 0,
                    generation: 1
                )
            }
            func purge() async {}
            func shutdown() async {}
            var indexCalls: Int { lock.withLock { calls } }
        }

        let clock = Clock()
        let coordinator = LibraryResourceCoordinator(
            runtimeState: LibraryRuntimeState(),
            monotonicNow: { clock.now() }
        )
        let native = Native(clock: clock)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [localModelEntry()]),
            payloads: [:],
            assets: [uid("a"), uid("b"), uid("c")],
            retryDelay: .seconds(60),
            nativeSearchFactoryOverride: { native },
            advertisedNativeSearchBackends: [.recognizedText],
            resourceCoordinator: coordinator,
            indexingCapacityProfile: .sustained
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: localModelEntry().id)
        #expect(await waitUntil(timeout: .seconds(1)) { native.indexCalls >= 3 })

        await harness.lifecycle.shutdown()
    }

    @Test func modelWithoutHostedArtifactReportsNotDownloadable() async throws {
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [.tinyCLIPVit40M]),
            payloads: [:],
            assets: [uid("a")]
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: MLModelCatalogEntry.tinyCLIPVit40M.id)
        #expect(await harness.lifecycle.currentSnapshot().phase == .notInstalled(downloadable: false))
        #expect(harness.transport.downloadCount == 0)
    }

    @Test func failedDownloadIsRetryable() async throws {
        let payload = Data("retry-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-retry", payload: payload)
        let assets = [uid("a"), uid("b")]
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: assets,
            failFirst: [urlA: 1]
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        let failed = await waitUntil {
            if case .failed(let failure) = await harness.lifecycle.currentSnapshot().phase {
                return failure.kind == .download && failure.isRetryable
            }
            return false
        }
        #expect(failed)

        await harness.lifecycle.retry()
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        #expect(harness.transport.downloadCount == 2)
    }

    @Test func checksumMismatchFailsVerificationAndNeverActivates() async throws {
        let payload = Data("good-bytes".utf8)
        let urlA = URL(string: "https://example.test/model-bad/weights.bin")!
        // Pin a different hash than what the transport serves.
        let wrongSpec = MLModelArtifactSpec(
            relativePath: "Model.mlmodelc/weights.bin", sha256: sha256(Data("other".utf8)),
            byteCount: Int64(payload.count))
        let entryA = MLModelCatalogEntry(
            id: MLModelID("model-bad"),
            displayName: "model-bad",
            family: "Test",
            descriptor: MLModelDescriptor(identifier: "model-bad", version: 1, embeddingDimension: 4),
            tokenizerID: "t",
            preprocessingID: "p",
            license: .mit,
            releaseTrack: .production,
            estimatedInstalledBytes: 1,
            downloadPlan: MLModelDownloadPlan(revision: "rev1", items: [.init(url: urlA, artifact: wrongSpec)])
        )
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: [uid("a")])
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        let failed = await waitUntil {
            if case .failed(let failure) = await harness.lifecycle.currentSnapshot().phase {
                return failure.kind == .verification
            }
            return false
        }
        #expect(failed)
        #expect(harness.provider.builtCount == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.layout.modelDirectory(for: entryA.id).path))
    }

    #if DEBUG
        @Test func completedIndexBecomesReadyAfterSelectionPublicationResumes() async throws {
            let payload = Data("model-a-bytes".utf8)
            let (entry, url) = downloadableEntry(id: "model-a", payload: payload)
            let assets = (0..<5).map { uid("asset-\($0)") }
            let harness = try makeHarness(
                catalog: MLModelCatalog(entries: [entry]), payloads: [url: payload], assets: assets)
            defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
            let gate = OneShotEmbeddingBarrier()
            await gate.arm()
            await harness.lifecycle.setSelectionCompletionGate { await gate.waitIfArmed() }
            // Smart Search is on without a model, for example after the catalog dropped it; the model is chosen again.
            try harness.stateStore.save(MLSmartSearchPersistentState(isEnabled: true))

            await harness.lifecycle.start()
            let selection = Task { await harness.lifecycle.select(entry.id) }
            await gate.waitUntilBlocked()
            #expect(
                await waitUntil {
                    let snapshot = await harness.lifecycle.currentSnapshot()
                    if case .ready(let progress) = snapshot.indexingState {
                        return progress.totalWorkUnits == assets.count
                            && progress.settledWorkUnits == assets.count
                    }
                    return false
                })
            #expect(await harness.lifecycle.semanticIndexedAssetCount() == assets.count)

            await gate.release()
            await selection.value
            #expect(await waitForCompleteIndex(harness, total: assets.count))
            await harness.lifecycle.shutdown()
        }

        @Test func selectionCompletionPreservesIndexFailureBackoff() async throws {
            let payload = Data("model-a-bytes".utf8)
            let (entry, url) = downloadableEntry(id: "model-a", payload: payload)
            let harness = try makeHarness(
                catalog: MLModelCatalog(entries: [entry]), payloads: [url: payload],
                assets: [uid("asset")], retryDelay: .seconds(30))
            defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
            let session = TrackingSession(descriptor: entry.descriptor, indexFails: true)
            harness.provider.sessionOverride = { _ in session }
            let gate = OneShotEmbeddingBarrier()
            await gate.arm()
            await harness.lifecycle.setSelectionCompletionGate { await gate.waitIfArmed() }
            // Smart Search is on without a model, for example after the catalog dropped it; the model is chosen again.
            try harness.stateStore.save(MLSmartSearchPersistentState(isEnabled: true))

            await harness.lifecycle.start()
            let selection = Task { await harness.lifecycle.select(entry.id) }
            await gate.waitUntilBlocked()
            #expect(
                await waitUntil {
                    if case .failed = await harness.lifecycle.currentSnapshot().indexingState {
                        return true
                    }
                    return false
                })
            #expect(session.indexCount == 1)

            await gate.release()
            await selection.value
            let retriedEarly = await waitUntil(timeout: .milliseconds(250)) {
                session.indexCount > 1
            }
            #expect(!retriedEarly)
            #expect(session.indexCount == 1)
            await harness.lifecycle.shutdown()
        }
    #endif

    @Test func sameSelectionDoesNotReindex() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let assets = (0..<5).map { uid("asset-\($0)") }
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: assets)
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        let sessionsBefore = harness.provider.builtCount
        let embedsBefore = harness.provider.embedder.totalCalls

        await harness.lifecycle.select(entryA.id)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(harness.provider.builtCount == sessionsBefore)
        #expect(harness.provider.embedder.totalCalls == embedsBefore)
    }

    @Test func modelSwitchUsesActivatedDescriptorAfterCatalogDrift() async throws {
        let payloadA = Data("model-a-bytes".utf8)
        let payloadB = Data("model-b-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payloadA)
        let (entryB, urlB) = downloadableEntry(id: "model-b", payload: payloadB)
        let driftedEntryA = descriptorDriftedEntry(from: entryA, version: 2)
        let catalogProvider = RecordingCatalogProvider(MLModelCatalog(entries: [entryA, entryB]))
        let assets = [uid("asset")]
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA, entryB]),
            payloads: [urlA: payloadA, urlB: payloadB],
            assets: assets,
            catalogProvider: catalogProvider,
            catalogRefreshInterval: .zero
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        #expect(await waitForCompleteIndex(harness, total: assets.count))

        await catalogProvider.replace(MLModelCatalog(entries: [driftedEntryA, entryB]))
        await harness.lifecycle.noteConditionsChanged()
        #expect(
            await waitUntil {
                let snapshot = await harness.lifecycle.currentSnapshot()
                return snapshot.availableModels.contains { $0.descriptor == driftedEntryA.descriptor }
            })
        #expect(harness.storeProvider.store.count(for: entryA.descriptor) == assets.count)

        await harness.lifecycle.select(entryB.id)
        #expect(await waitForCompleteIndex(harness, total: assets.count))

        #expect(harness.storeProvider.store.count(for: entryA.descriptor) == 0)
        #expect(harness.storeProvider.store.count(for: entryB.descriptor) == assets.count)
    }

    @Test func sameIDAutomaticRevisionUpdateReloadsOnceAndInvalidatesOldVectors() async throws {
        let payloadV1 = Data("model-v1".utf8)
        let payloadV2 = Data("model-v2".utf8)
        let (entryV1, urlV1) = downloadableEntry(id: "model", payload: payloadV1, revision: "rev1")
        let (entryV2, urlV2) = downloadableEntry(id: "model", payload: payloadV2, revision: "rev2")
        let assets = [uid("asset")]
        let catalogProvider = RecordingCatalogProvider(MLModelCatalog(entries: [entryV1]))
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryV1]),
            payloads: [urlV1: payloadV1, urlV2: payloadV2],
            assets: assets,
            catalogProvider: catalogProvider,
            catalogRefreshInterval: .zero
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryV1.id)
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        #expect(harness.provider.builtCount == 1)
        #expect(harness.storeProvider.store.count(for: entryV1.descriptor) == assets.count)

        await catalogProvider.replace(MLModelCatalog(entries: [entryV2]))
        await harness.lifecycle.noteConditionsChanged()

        #expect(
            await waitUntil {
                harness.provider.builtCount == 2
                    && (try? harness.stateStore.load()?.activatedRevision) == "rev2"
            })
        #expect(try harness.stateStore.load()?.activatedDescriptor == entryV2.descriptor)
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        #expect(harness.transport.downloadCount == 2)
        #expect(harness.provider.embedder.totalCalls == 2)
        #expect(harness.storeProvider.store.count(for: entryV1.descriptor) == assets.count)

        // A catalog entry without a hosted plan must not reload an already active model.
        let unhostedV2 = MLModelCatalogEntry(
            id: entryV2.id,
            compatibilityKey: entryV2.compatibilityKey,
            displayName: entryV2.displayName,
            family: entryV2.family,
            role: entryV2.role,
            capabilities: entryV2.capabilities,
            sourceRevision: entryV2.sourceRevision,
            descriptor: entryV2.descriptor,
            tokenizerID: entryV2.tokenizerID,
            preprocessingID: entryV2.preprocessingID,
            runtimeContract: entryV2.runtimeContract,
            relevancePolicy: entryV2.relevancePolicy,
            runtimeResourcePaths: entryV2.runtimeResourcePaths,
            license: entryV2.license,
            releaseTrack: entryV2.releaseTrack,
            localizedMetadata: entryV2.localizedMetadata,
            estimatedInstalledBytes: entryV2.estimatedInstalledBytes,
            downloadPlan: nil,
            releaseQualification: nil
        )
        await catalogProvider.replace(MLModelCatalog(entries: [unhostedV2]))
        await harness.lifecycle.noteConditionsChanged()
        await harness.lifecycle.noteConditionsChanged()
        #expect(harness.provider.builtCount == 2)
    }

    @Test func periodicCatalogRefreshAdoptsCompatibleRevisionWithoutHostEvent() async throws {
        let payloadV1 = Data("model-v1".utf8)
        let payloadV2 = Data("model-v2".utf8)
        let (entryV1, urlV1) = downloadableEntry(id: "model", payload: payloadV1, revision: "rev1")
        let (entryV2, urlV2) = downloadableEntry(
            id: "model",
            payload: payloadV2,
            revision: "rev2",
            descriptorVersion: 2
        )
        let catalogProvider = RecordingCatalogProvider(MLModelCatalog(entries: [entryV1]))
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryV1]),
            payloads: [urlV1: payloadV1, urlV2: payloadV2],
            assets: [uid("asset")],
            catalogProvider: catalogProvider,
            catalogRefreshInterval: .milliseconds(10)
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryV1.id)
        #expect(await waitForCompleteIndex(harness, total: 1))

        await catalogProvider.replace(MLModelCatalog(entries: [entryV2]))

        #expect(
            await waitUntil(timeout: .seconds(3)) {
                (try? harness.stateStore.load()?.activatedRevision) == "rev2"
            })
        #expect(await waitForCompleteIndex(harness, total: 1))
        #expect(try harness.stateStore.load()?.activatedDescriptor == entryV2.descriptor)
        await harness.lifecycle.shutdown()
    }

    @Test func coldStartRevisionUpdateRetiresPreviousDescriptorVectors() async throws {
        let payloadV1 = Data("model-v1".utf8)
        let payloadV2 = Data("model-v2".utf8)
        let (entryV1, urlV1) = downloadableEntry(id: "model", payload: payloadV1, revision: "rev1")
        let (entryV2, urlV2) = downloadableEntry(
            id: "model",
            payload: payloadV2,
            revision: "rev2",
            descriptorVersion: 2
        )
        let assets = [uid("asset")]
        let transport = ScriptedTransport(payloads: [urlV1: payloadV1, urlV2: payloadV2])
        let first = try makeHarness(
            catalog: MLModelCatalog(entries: [entryV1]),
            payloads: [urlV1: payloadV1, urlV2: payloadV2],
            assets: assets,
            transportOverride: transport
        )
        defer { try? FileManager.default.removeItem(at: first.layout.rootDirectory) }

        await first.lifecycle.start()
        await first.lifecycle.enable(with: entryV1.id)
        #expect(await waitForCompleteIndex(first, total: assets.count))
        #expect(first.provider.embedder.totalCalls == 1)
        await first.lifecycle.shutdown()

        let second = try makeHarness(
            catalog: MLModelCatalog(entries: [entryV2]),
            payloads: [urlV1: payloadV1, urlV2: payloadV2],
            assets: assets,
            root: first.layout.rootDirectory,
            stateStoreOverride: first.stateStore,
            storeProviderOverride: first.storeProvider,
            transportOverride: transport
        )
        await second.lifecycle.start()

        #expect(await waitForCompleteIndex(second, total: assets.count))
        #expect(second.provider.embedder.totalCalls == 1)
        #expect(try second.stateStore.load()?.activatedRevision == "rev2")
        #expect(try second.stateStore.load()?.activatedDescriptor == entryV2.descriptor)
        #expect(second.storeProvider.store.count(for: entryV1.descriptor) == 0)
        #expect(second.storeProvider.store.count(for: entryV2.descriptor) == assets.count)
    }

    @Test func shutdownJoinsActivationBeforeClosingItsStore() async throws {
        let payload = Data("model-bytes".utf8)
        let (entry, url) = downloadableEntry(id: "model", payload: payload)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]),
            payloads: [url: payload],
            assets: [uid("asset")]
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        harness.provider.blockNextSessionLoad()
        let activation = Task { await harness.lifecycle.enable(with: entry.id) }
        #expect(await waitUntil { harness.provider.sessionLoadStarted })

        let shutdown = Task { await harness.lifecycle.shutdown() }
        #expect(await waitUntil { harness.provider.sessionLoadCancellations == 1 })
        #expect(harness.storeProvider.closeCount == 0)
        harness.provider.releaseBlockedSessionLoad()
        await shutdown.value
        await activation.value

        #expect(harness.storeProvider.closeCount == 1)
        #expect(try harness.stateStore.load()?.activatedRevision == nil)
        await #expect(throws: MLSmartSearchQueryError.unavailable) {
            _ = try await harness.lifecycle.search("anything", limit: 3)
        }
    }

    #if DEBUG
        @Test func developerInstallAfterTurningOffNeitherRevivesNorOrphansTheModel() async throws {
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
            let harness = try makeHarness(
                catalog: MLModelCatalog(entries: [entry]),
                payloads: [:],
                assets: [uid("asset")]
            )
            defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
            let artifact = FileManager.default.temporaryDirectory
                .appendingPathComponent("ml-dev-artifact-\(UUID().uuidString)", isDirectory: true)
            let model = artifact.appendingPathComponent("Test.mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            try Data("weights".utf8).write(to: model.appendingPathComponent("model.bin"))
            defer { try? FileManager.default.removeItem(at: artifact) }

            await harness.lifecycle.start()
            await harness.lifecycle.enable(with: entry.id)
            let gate = ContinuationGate()
            await harness.lifecycle.setDeveloperInstallContinuationGate { await gate.wait() }

            let install = Task { await harness.lifecycle.installDeveloperModel(from: artifact, for: entry.id) }
            #expect(await waitUntil { gate.hasEntered })
            #expect(FileManager.default.fileExists(atPath: harness.layout.modelDirectory(for: entry.id).path))

            await harness.lifecycle.disableAndPurge()
            #expect(!(await harness.lifecycle.currentSnapshot().isEnabled))
            gate.release()
            await install.value

            let snapshot = await harness.lifecycle.currentSnapshot()
            #expect(!snapshot.isEnabled)
            #expect(snapshot.selectedModelID == nil)
            #expect(!FileManager.default.fileExists(atPath: harness.layout.modelDirectory(for: entry.id).path))
        }
    #endif

    private final class ContinuationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        var hasEntered: Bool { lock.withLock { entered } }

        /// Only the first caller blocks. Later callers pass through, so a regression that starts a
        /// second operation fails its assertions instead of hanging the test run.
        func wait() async {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    if released || entered { return true }
                    entered = true
                    self.continuation = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func release() {
            let waiting = lock.withLock {
                released = true
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume()
        }
    }

    private final class CommitCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    @Test func activationCannotCommitAfterNewerSelection() async throws {
        let payloadA = Data("model-a-bytes".utf8)
        let payloadB = Data("model-b-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payloadA)
        let (entryB, urlB) = downloadableEntry(id: "model-b", payload: payloadB)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA, entryB]),
            payloads: [urlA: payloadA, urlB: payloadB],
            assets: [uid("asset")]
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        harness.provider.blockNextSessionLoad()
        let activationA = Task { await harness.lifecycle.enable(with: entryA.id) }
        #expect(await waitUntil { harness.provider.sessionLoadStarted })

        let activationB = Task { await harness.lifecycle.select(entryB.id) }
        #expect(
            await waitUntil {
                await harness.lifecycle.currentSnapshot().selectedModelID == entryB.id
            })
        #expect(await waitUntil { harness.provider.sessionLoadCancellations == 1 })
        #expect(FileManager.default.fileExists(atPath: harness.layout.modelDirectory(for: entryA.id).path))
        harness.provider.releaseBlockedSessionLoad()
        await activationA.value
        await activationB.value

        #expect(await waitForCompleteIndex(harness, total: 1))
        #expect(await harness.lifecycle.currentSnapshot().selectedModelID == entryB.id)
        #expect(harness.provider.builtCount == 2)
        #expect(try harness.stateStore.load()?.selectedModelID == entryB.id)
        #expect(!FileManager.default.fileExists(atPath: harness.layout.modelDirectory(for: entryA.id).path))
    }

    @Test func modelSwitchRetiresOldEpochCompletely() async throws {
        let payloadA = Data("model-a-bytes".utf8)
        let payloadB = Data("model-b-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payloadA)
        let (entryB, urlB) = downloadableEntry(id: "model-b", payload: payloadB)
        let assets = (0..<10).map { uid("asset-\($0)") }
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA, entryB]),
            payloads: [urlA: payloadA, urlB: payloadB],
            assets: assets
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        #expect(harness.storeProvider.store.count(for: entryA.descriptor) == assets.count)

        await harness.lifecycle.select(entryB.id)
        #expect(await waitForCompleteIndex(harness, total: assets.count))

        // The previous epoch has no rows or artifacts, and the selected epoch is complete.
        #expect(harness.storeProvider.store.count(for: entryA.descriptor) == 0)
        #expect(harness.storeProvider.store.count(for: entryB.descriptor) == assets.count)
        #expect(!FileManager.default.fileExists(atPath: harness.layout.modelDirectory(for: entryA.id).path))
        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.selectedModelID == entryB.id)

        let results = try await harness.lifecycle.search("anything", limit: 5)
        #expect(results.descriptor == entryB.descriptor)
    }

    @Test func cancelledNativeSuppressionReadCannotPublishRetiredStorageFailure() async throws {
        let asset = uid("native-suppressed")
        let suppressionRead = BlockingSuppressionRead(result: [asset])
        let native = RecordingNativeSearch(
            results: [],
            permanentlyUnavailable: [asset],
            suppressionRead: suppressionRead
        )
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [localModelEntry()]),
            payloads: [:],
            assets: [asset],
            nativeSearch: native
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        let stream = await harness.lifecycle.snapshots()
        let observations = Task {
            var snapshots: [MLSmartSearchSnapshot] = []
            for await snapshot in stream { snapshots.append(snapshot) }
            return snapshots
        }
        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: localModelEntry().id)
        await suppressionRead.waitUntilStarted()

        let stopping = Task { await harness.lifecycle.setIndexingExecutionAllowed(false) }
        await suppressionRead.waitUntilCancelled()
        await stopping.value

        if case .failed(let failure) = await harness.lifecycle.currentSnapshot().indexingState {
            #expect(failure.debugDescription != "native analysis suppression state unavailable")
        }
        await harness.lifecycle.shutdown()
        let snapshots = await observations.value
        #expect(
            !snapshots.contains { snapshot in
                guard case .failed(let failure) = snapshot.indexingState else { return false }
                return failure.debugDescription == "native analysis suppression state unavailable"
            }, "Even a briefly published retired storage failure violates the session boundary")
    }

    @Test func replacedSemanticSessionCannotPublishRetiredSuppressionFailure() async throws {
        let asset = uid("semantic-suppressed")
        let suppressionRead = BlockingSuppressionRead(result: [asset])
        let payload = Data("semantic-suppression-model".utf8)
        let (entryA, urlA) = downloadableEntry(id: "suppression-a", payload: payload)
        let (entryB, urlB) = downloadableEntry(id: "suppression-b", payload: payload)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA, entryB]),
            payloads: [urlA: payload, urlB: payload],
            assets: [asset]
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        harness.provider.sessionOverride = { model in
            if model.entry.id == entryA.id {
                return FixedSemanticSession(
                    descriptor: model.entry.descriptor,
                    permanentlyUnavailable: [asset],
                    suppressionRead: suppressionRead
                )
            }
            return FixedSemanticSession(descriptor: model.entry.descriptor)
        }

        let stream = await harness.lifecycle.snapshots()
        let observations = Task {
            var snapshots: [MLSmartSearchSnapshot] = []
            for await snapshot in stream { snapshots.append(snapshot) }
            return snapshots
        }
        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        await suppressionRead.waitUntilStarted()

        let switching = Task { await harness.lifecycle.select(entryB.id) }
        await suppressionRead.waitUntilCancelled()
        await switching.value

        #expect(await harness.lifecycle.currentSnapshot().selectedModelID == entryB.id)
        if case .failed(let failure) = await harness.lifecycle.currentSnapshot().indexingState {
            #expect(failure.debugDescription != "semantic suppression state unavailable")
        }
        await harness.lifecycle.shutdown()
        let snapshots = await observations.value
        #expect(
            !snapshots.contains { snapshot in
                guard case .failed(let failure) = snapshot.indexingState else { return false }
                return failure.debugDescription == "semantic suppression state unavailable"
            }, "Even a briefly published retired storage failure violates the session boundary")
    }

    @Test func staleQueryFromPreviousEpochIsDiscarded() async throws {
        /// Session whose search blocks until released.
        final class BlockingSession: MLSmartSearchSession, @unchecked Sendable {
            let descriptor: MLModelDescriptor
            private let lock = NSLock()
            private var releaseSearch: CheckedContinuation<Void, Never>?
            private var released = false

            init(descriptor: MLModelDescriptor) { self.descriptor = descriptor }

            func index(_ assets: [PhotoUID], observer: MLIndexPassObserver) async -> MLIndexPassOutcome {
                MLIndexPassOutcome(
                    report: MLIndexBatchReport(total: assets.count, skippedAlreadyIndexed: assets.count),
                    ranToCompletion: true,
                    newPermanentFailures: [],
                    progress: MLIndexProgress(
                        phase: .completed,
                        descriptor: descriptor,
                        totalAssets: assets.count,
                        alreadyIndexed: assets.count
                    )
                )
            }

            func search(_ text: String, limit: Int) async throws -> MLSearchResults {
                await withCheckedContinuation { continuation in
                    let alreadyReleased = lock.withLock {
                        if released { return true }
                        releaseSearch = continuation
                        return false
                    }
                    if alreadyReleased { continuation.resume() }
                }
                return MLSearchResults(
                    descriptor: descriptor, queryText: text,
                    results: [
                        MLSearchResult(uid: PhotoUID(volumeID: "vol1", nodeID: "old-epoch"), score: 1)
                    ])
            }

            func release() {
                let continuation = lock.withLock {
                    released = true
                    let c = releaseSearch
                    releaseSearch = nil
                    return c
                }
                continuation?.resume()
            }

            func releaseMemory() async {}
            func shutdown() async {}
        }

        let payloadA = Data("model-a-bytes".utf8)
        let payloadB = Data("model-b-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payloadA)
        let (entryB, urlB) = downloadableEntry(id: "model-b", payload: payloadB)
        let assets = [uid("asset-0")]
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA, entryB]),
            payloads: [urlA: payloadA, urlB: payloadB],
            assets: assets
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        let blockingSession = BlockingSession(descriptor: entryA.descriptor)
        harness.provider.sessionOverride = { model in
            model.entry.id == entryA.id
                ? blockingSession
                : BlockingSession(descriptor: model.entry.descriptor)
        }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        _ = await waitUntil {
            if case .ready = await harness.lifecycle.currentSnapshot().phase { return true }
            return false
        }

        // The query is in flight.
        let pending = Task { try await harness.lifecycle.search("old query", limit: 5) }
        try? await Task.sleep(for: .milliseconds(100))
        // The model switches while the query is in flight.
        let switching = Task { await harness.lifecycle.select(entryB.id) }
        #expect(
            await waitUntil {
                let snapshot = await harness.lifecycle.currentSnapshot()
                return snapshot.selectedModelID == entryB.id && !snapshot.isSearchAvailable
            })
        // The query completes after the switch and must be discarded.
        blockingSession.release()
        await #expect(throws: MLSmartSearchQueryError.staleEpoch) {
            _ = try await pending.value
        }
        await switching.value
    }

    @Test func newAndDeletedAssetsReconcileDuringIndexing() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let initial = (0..<4).map { uid("asset-\($0)") }
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: initial)
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        #expect(await waitForCompleteIndex(harness, total: initial.count))

        // New asset arrives, one asset is deleted.
        let added = uid("asset-new")
        var next = initial
        next.removeFirst()
        next.append(added)
        harness.assets.set(next)
        await harness.lifecycle.noteLibraryChanged()

        #expect(
            await waitUntil {
                harness.storeProvider.store.contains(uid: added, descriptor: entryA.descriptor)
                    && !harness.storeProvider.store.contains(uid: initial[0], descriptor: entryA.descriptor)
            })
        // No duplicate work: unchanged assets embedded exactly once.
        #expect(harness.provider.embedder.callCount(initial[1]) == 1)
    }

    @Test func hydratingInventoryNeverAuthorizesSemanticDeletion() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entry, url) = downloadableEntry(id: "model-a", payload: payload)
        let initial = (0..<4).map { uid("asset-\($0)") }
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]),
            payloads: [url: payload],
            assets: initial,
            retryDelay: .milliseconds(20)
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entry.id)
        #expect(await waitForCompleteIndex(harness, total: initial.count))

        harness.assets.beginHydration()
        await harness.lifecycle.noteLibraryChanged()
        #expect(
            await waitUntil {
                if case .waiting = await harness.lifecycle.currentSnapshot().indexingState {
                    return true
                }
                return false
            })
        #expect(harness.storeProvider.store.count(for: entry.descriptor) == initial.count)

        let retained = Array(initial.dropFirst())
        harness.assets.set(retained)
        await harness.lifecycle.noteLibraryChanged()
        #expect(
            await waitUntil {
                !harness.storeProvider.store.contains(uid: initial[0], descriptor: entry.descriptor)
            })
        #expect(harness.storeProvider.store.count(for: entry.descriptor) == retained.count)
    }

    @Test func authoritativeInventoryRemovesVectorsAddedDuringHydration() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entry, url) = downloadableEntry(id: "model-a", payload: payload)
        let retained = uid("retained")
        let transient = uid("transient")
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]),
            payloads: [url: payload],
            assets: [retained],
            retryDelay: .milliseconds(20)
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entry.id)
        #expect(await waitForCompleteIndex(harness, total: 1))

        harness.assets.setHydrating([retained, transient])
        await harness.lifecycle.noteLibraryChanged()
        #expect(
            await waitUntil {
                harness.storeProvider.store.contains(
                    uid: transient,
                    descriptor: entry.descriptor
                )
            }
        )

        harness.assets.set([retained])
        await harness.lifecycle.noteLibraryChanged()
        #expect(
            await waitUntil {
                !harness.storeProvider.store.contains(
                    uid: transient,
                    descriptor: entry.descriptor
                )
            }
        )
        #expect(harness.storeProvider.store.count(for: entry.descriptor) == 1)
    }

    @Test func readyStatusStaysStableUntilRealEmbeddingStarts() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let initial = [uid("asset-0")]
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: initial
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        #expect(await waitForCompleteIndex(harness, total: initial.count))

        let phases = PhaseRecorder()
        let observation = Task {
            for await snapshot in await harness.lifecycle.snapshots() {
                phases.append(snapshot.phase)
            }
        }
        defer { observation.cancel() }
        #expect(await waitUntil { !phases.isEmpty })
        phases.reset()

        // A no-op catch-up must never make the ready copy flicker to "preparing".
        await harness.lifecycle.noteLibraryChanged()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!phases.sawIndexing)
        if case .ready = await harness.lifecycle.currentSnapshot().phase {
            // Expected.
        } else {
            Issue.record("no-op indexing pass changed the ready status")
        }
        phases.reset()

        // A library kick starts planning immediately, but the visible ready state remains stable
        // while the first thumbnail is still being acquired and embedded.
        let callsBeforeLibraryKick = harness.provider.embedder.totalCalls
        await harness.provider.embedder.blockNextEmbedding()
        let added = (0..<8).map { uid("asset-new-\($0)") }
        harness.assets.set(initial + added)
        await harness.lifecycle.noteLibraryChanged()

        await harness.provider.embedder.waitUntilEmbeddingStarted()
        if case .ready = await harness.lifecycle.currentSnapshot().phase {
            // Expected: planning and thumbnail acquisition remain invisible maintenance.
        } else {
            Issue.record("ready status changed before a real embedding was produced")
        }
        #expect(!phases.sawIndexing)

        // Visibility events are best-effort. Keep the pass alive at the next embedding so
        // its first produced-embedding event cannot be retired before the observer consumes it.
        // Re-arming and releasing must be one barrier operation; separate calls would race.
        await harness.provider.embedder.releaseEmbeddingAndBlockNext()
        await harness.provider.embedder.waitUntilEmbeddingStarted()
        #expect(await waitUntil { phases.sawIndexing })
        #expect(harness.provider.embedder.totalCalls > callsBeforeLibraryKick)
        if case .indexing = await harness.lifecycle.currentSnapshot().phase {
            // Real work is now visible while the next embedding remains blocked.
        } else {
            Issue.record("ongoing indexing did not publish its produced embedding")
        }
        await harness.provider.embedder.releaseEmbedding()
        #expect(await waitForCompleteIndex(harness, total: initial.count + added.count))
    }

    @Test func closedGovernorRechecksAndResumesWithoutAHostKick() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let assets = (0..<6).map { uid("asset-\($0)") }
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: assets,
            retryDelay: .seconds(60),
            closedGateRecheckDelay: .milliseconds(50)
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        harness.governor.set(false)
        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        _ = await waitUntil {
            if case .waiting = await harness.lifecycle.currentSnapshot().phase { return true }
            return false
        }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(harness.provider.embedder.totalCalls == 0)

        harness.governor.set(true)
        #expect(await waitForCompleteIndex(harness, total: assets.count))
    }

    @Test func aClosedGateWaitsForAWakeInsteadOfPollingEverySecond() async throws {
        #expect(MLSmartSearchLifecycle.Configuration().closedGateRecheckDelay == .seconds(30))
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let assets = (0..<6).map { uid("asset-\($0)") }
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: assets,
            closedGateRecheckDelay: MLSmartSearchLifecycle.Configuration().closedGateRecheckDelay
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        harness.governor.set(false)
        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        try #require(
            await waitUntil {
                if case .waiting = await harness.lifecycle.currentSnapshot().phase { return true }
                return false
            })
        let checksWhileClosed = harness.governor.checkCount
        // A 1 s recheck would ask the gate at least twice more in this time.
        try await Task.sleep(for: .milliseconds(2_500))
        #expect(harness.governor.checkCount - checksWhileClosed <= 1)
        #expect(harness.provider.embedder.totalCalls == 0)

        // The host reports the change, and indexing resumes at once instead of after the fallback.
        harness.governor.set(true)
        await harness.lifecycle.noteConditionsChanged()
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                let snapshot = await harness.lifecycle.currentSnapshot()
                if case .ready(let coverage) = snapshot.phase {
                    return coverage.isComplete && coverage.total == assets.count
                }
                return false
            })
        await harness.lifecycle.shutdown()
    }

    @Test func shutdownCancelsAClosedGateWaitWithoutWaitingForTheFallback() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entry, url) = downloadableEntry(id: "model-a", payload: payload)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]), payloads: [url: payload], assets: [uid("asset")],
            closedGateRecheckDelay: MLSmartSearchLifecycle.Configuration().closedGateRecheckDelay
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        harness.governor.set(false)
        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entry.id)
        try #require(
            await waitUntil {
                if case .waiting = await harness.lifecycle.currentSnapshot().phase { return true }
                return false
            })
        let started = ContinuousClock.now
        await harness.lifecycle.shutdown()
        #expect(started.duration(to: .now) < .seconds(5))
        harness.governor.set(true)
        await harness.lifecycle.noteConditionsChanged()
        #expect(harness.provider.embedder.totalCalls == 0)
    }

    @Test func disablePurgesEverythingAndIsIdempotent() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let assets = (0..<6).map { uid("asset-\($0)") }
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: assets)
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        // Sibling file outside the Smart Search root must survive the purge.
        let sibling = harness.layout.rootDirectory.deletingLastPathComponent()
            .appendingPathComponent("unrelated-\(UUID().uuidString).txt")
        try Data("keep me".utf8).write(to: sibling)
        defer { try? FileManager.default.removeItem(at: sibling) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        #expect(FileManager.default.fileExists(atPath: harness.layout.rootDirectory.path))

        await harness.lifecycle.disableAndPurge()
        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.phase == .disabled)
        #expect(!snapshot.isEnabled)
        #expect(!snapshot.isSearchAvailable)
        // The entire Smart Search root is gone: index DB + WAL/SHM, models, tmp, state file.
        #expect(!FileManager.default.fileExists(atPath: harness.layout.rootDirectory.path))
        #expect(FileManager.default.fileExists(atPath: sibling.path))
        #expect(try harness.stateStore.load() == nil)

        // Second disable is harmless.
        await harness.lifecycle.disableAndPurge()
        #expect(await harness.lifecycle.currentSnapshot().phase == .disabled)
    }

    @Test func purgeInventoryRemovesRealDatabaseAndSidecars() async throws {
        struct IdentityCipher: MLVectorCipher {
            func seal(_ plaintext: Data, context: MLVectorCipherContext) throws -> Data { plaintext }
            func open(_ ciphertext: Data, context: MLVectorCipherContext) throws -> Data { ciphertext }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-purge-inventory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)

        // Create the full artifact inventory: SQLite DB (+WAL via a write), a model install,
        // a partial download, and the state file.
        let storeProvider = SQLiteMLIndexStoreProvider(url: layout.indexDatabaseURL, cipher: IdentityCipher())
        let store = try #require(storeProvider.openStore())
        let descriptor = MLModelDescriptor(identifier: "model-a", version: 1, embeddingDimension: 4)
        store.upsert([MLEmbeddingRecord(uid: uid("a"), descriptor: descriptor, vector: [1, 0, 0, 0])])

        try FileManager.default.createDirectory(
            at: layout.installDirectory(for: MLModelID("model-a"), revision: "rev1"), withIntermediateDirectories: true)
        let installedModel = layout.installDirectory(for: MLModelID("model-a"), revision: "rev1")
            .appendingPathComponent("Model.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: installedModel, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: installedModel.appendingPathComponent("weights.bin"))
        try FileManager.default.createDirectory(at: layout.temporaryDirectory, withIntermediateDirectories: true)
        let partial = layout.stagingDirectory(for: MLModelID("model-a"), revision: "rev2")
            .appendingPathComponent("Model.mlmodelc/weights.bin.partial")
        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: partial)
        let stateStore = FileMLSmartSearchStateStore(layout: layout)
        try stateStore.save(
            MLSmartSearchPersistentState(
                isEnabled: true,
                selectedModelID: MLModelID("model-a")
            ))

        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: [uid("a")],
            root: root
        )

        // Use the SQLite-backed provider for this test so purge must close real handles.
        let lifecycle = MLSmartSearchLifecycle(
            dependencies: .init(
                catalog: MLModelCatalog(entries: [entryA]),
                layout: layout,
                stateStore: stateStore,
                installer: MLModelInstaller(layout: layout, transport: harness.transport),
                storeProvider: storeProvider,
                runtimeProvider: harness.provider,
                assetsProvider: { .authoritative([PhotoUID(volumeID: "vol1", nodeID: "a")]) },
                governor: MLAlwaysPermitsIndexing(),
                allowsDeveloperModels: true
            )
        )
        await lifecycle.start()
        await lifecycle.disableAndPurge()

        #expect(!FileManager.default.fileExists(atPath: root.path))
        for url in layout.indexDatabaseFileURLs {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func crashDuringPurgeCompletesOnNextStart() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-crash-purge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)

        // Simulate a crash mid-purge: journal written, files still present.
        let stateStore = FileMLSmartSearchStateStore(layout: layout)
        try stateStore.save(
            MLSmartSearchPersistentState(
                isEnabled: false,
                selectedModelID: entryA.id,
                pendingOperation: .purge
            ))
        try FileManager.default.createDirectory(at: layout.modelsDirectory, withIntermediateDirectories: true)
        try Data("leftover".utf8).write(to: layout.modelsDirectory.appendingPathComponent("leftover.bin"))

        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: [uid("a")], root: root)
        await harness.lifecycle.start()

        #expect(await harness.lifecycle.currentSnapshot().phase == .disabled)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func crashBetweenInstallAndActivationRecoversWithoutRedownload() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(
            id: "model-a",
            payload: payload,
            includeQualification: false
        )
        let assets = (0..<3).map { uid("asset-\($0)") }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-crash-activate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)

        // First session: install completes (transport used once), then "crash" before the
        // state store records the activation.
        let installTransport = ScriptedTransport(payloads: [urlA: payload])
        let installer = MLModelInstaller(layout: layout, transport: installTransport)
        _ = try await installer.install(entryA) { _ in }
        #expect(installTransport.downloadCount == 1)
        try FileMLSmartSearchStateStore(layout: layout).save(
            MLSmartSearchPersistentState(
                isEnabled: true,
                selectedModelID: entryA.id,
                activatedRevision: nil
            )
        )

        // Relaunch: activation resumes from the verified install with zero downloads.
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: assets, root: root)
        await harness.lifecycle.start()
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        #expect(harness.transport.downloadCount == 0)
    }

    @Test func crashMidSwitchRetiresOldEpochOnNextStart() async throws {
        let payloadA = Data("model-a-bytes".utf8)
        let payloadB = Data("model-b-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payloadA)
        let (entryB, urlB) = downloadableEntry(id: "model-b", payload: payloadB)
        let driftedEntryA = descriptorDriftedEntry(from: entryA, version: 2)
        let assets = (0..<3).map { uid("asset-\($0)") }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-crash-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)

        // Both models installed; switch journaled but interrupted before cleanup.
        let transport = ScriptedTransport(payloads: [urlA: payloadA, urlB: payloadB])
        let installer = MLModelInstaller(layout: layout, transport: transport)
        _ = try await installer.install(entryA) { _ in }
        _ = try await installer.install(entryB) { _ in }
        try FileMLSmartSearchStateStore(layout: layout).save(
            MLSmartSearchPersistentState(
                isEnabled: true,
                selectedModelID: entryB.id,
                activatedRevision: nil,
                activatedDescriptor: entryA.descriptor,
                pendingOperation: .switchModel(from: entryA.id, to: entryB.id)
            ))

        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [driftedEntryA, entryB]),
            payloads: [urlA: payloadA, urlB: payloadB],
            assets: assets,
            root: root
        )
        // Seed old-epoch rows that the recovery must remove.
        harness.storeProvider.store.upsert([
            MLEmbeddingRecord(uid: assets[0], descriptor: entryA.descriptor, vector: [1, 0, 0, 0])
        ])

        await harness.lifecycle.start()
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        #expect(harness.storeProvider.store.count(for: entryA.descriptor) == 0)
        #expect(harness.storeProvider.store.count(for: entryB.descriptor) == assets.count)
        #expect(
            await waitUntil {
                !FileManager.default.fileExists(atPath: layout.modelDirectory(for: entryA.id).path)
            })
        #expect(harness.transport.downloadCount == 0)
    }

    @Test func developerModelsAreInvisibleAndUnselectableWithoutTheCapability() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let (entryDev, _) = downloadableEntry(id: "model-dev", payload: payload, track: .developerOnly)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA, entryDev]),
            payloads: [urlA: payload],
            assets: [uid("a")],
            allowsDeveloperModels: false
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        _ = await waitForCompleteIndex(harness, total: 1)

        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.availableModels.map(\.id) == [entryA.id])

        await harness.lifecycle.select(entryDev.id)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await harness.lifecycle.currentSnapshot().selectedModelID == entryA.id)
    }

    @Test func downloadProgressIsMonotonicAndCoalesced() async throws {
        let payload = Data(repeating: 0xAB, count: 1 << 16)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: [uid("a")])
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        let fractions = Fractions()
        let observation = Task {
            for await snapshot in await harness.lifecycle.snapshots() {
                if case .downloading(let progress) = snapshot.phase, let fraction = progress.fraction {
                    fractions.append(fraction)
                }
            }
        }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        #expect(await waitForCompleteIndex(harness, total: 1))
        observation.cancel()

        let seen = fractions.values
        #expect(seen == seen.sorted(), "download progress must be monotonic")
        #expect(seen.contains { $0 > 0 && $0 < 1 }, "download progress must be visible before completion")
        #expect(seen.count <= 102, "download progress must be coalesced, saw \(seen.count) emissions")
    }

    private final class Fractions: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        func append(_ value: Double) { lock.withLock { storage.append(value) } }
        var values: [Double] { lock.withLock { storage } }
    }

    @Test func searchUnavailableWhileDisabledOrUncovered() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: [uid("a")])
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await #expect(throws: MLSmartSearchQueryError.unavailable) {
            _ = try await harness.lifecycle.search("query", limit: 5)
        }
    }

    private func makeFlakyHarness(
        catalog: MLModelCatalog,
        payloads: [URL: Data],
        assets: [PhotoUID]
    ) throws -> (Harness, FlakyStateStore) {
        let rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-lifecycle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let flaky = FlakyStateStore(layout: MLModelInstallLayout(rootDirectory: rootDir))
        let harness = try makeHarness(
            catalog: catalog,
            payloads: payloads,
            assets: assets,
            root: rootDir,
            stateStoreOverride: flaky
        )
        return (harness, flaky)
    }

    private func waitForStorageFailure(_ harness: Harness) async -> Bool {
        await waitUntil {
            if case .failed(let failure) = await harness.lifecycle.currentSnapshot().phase {
                return failure.kind == .storage && failure.isRetryable
            }
            return false
        }
    }

    @Test func failedEnableJournalWriteIsHonestAndRetryable() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let assets = (0..<3).map { uid("asset-\($0)") }
        let (harness, flaky) = try makeFlakyHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: assets
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        flaky.setFailing(true)
        await harness.lifecycle.enable(with: entryA.id)

        // The failed journal write is visible and retryable; and no download started on top
        // of an unpersisted enable.
        #expect(await waitForStorageFailure(harness))
        #expect(harness.transport.downloadCount == 0)
        #expect(try flaky.load() == nil)

        // Retry stores the intent and the chosen model again, then downloads and indexes.
        flaky.setFailing(false)
        await harness.lifecycle.retry()
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        #expect(try flaky.load()?.isEnabled == true)
        #expect(try flaky.load()?.selectedModelID == entryA.id)
    }

    @Test func failedActivationStateWriteClosesSessionAndNeverStartsIndexing() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let (harness, flaky) = try makeFlakyHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: [uid("asset-a")]
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        let recorder = SessionRecorder()
        harness.provider.sessionOverride = { recorder.make($0) }

        await harness.lifecycle.start()
        flaky.setFailingActivationWrites(true)
        await harness.lifecycle.enable(with: entryA.id)

        #expect(await waitForStorageFailure(harness))
        #expect(harness.provider.builtCount == 1)
        #expect(recorder.sessions.count == 1)
        #expect(recorder.sessions[0].shutdownCount == 1)
        #expect(recorder.sessions[0].indexCount == 0)
        #expect(try flaky.load()?.activatedRevision == nil)
        #expect(try flaky.load()?.activatedDescriptor == nil)
        await #expect(throws: MLSmartSearchQueryError.unavailable) {
            _ = try await harness.lifecycle.search("anything", limit: 3)
        }

        flaky.setFailingActivationWrites(false)
        await harness.lifecycle.retry()
        #expect(
            await waitUntil {
                recorder.sessions.count == 2 && recorder.sessions[1].indexCount > 0
            })
        #expect(harness.provider.builtCount == 2)
        #expect(recorder.sessions[0].shutdownCount == 1)
        await harness.lifecycle.shutdown()
    }

    @Test func knownPermanentRuntimeFailureBlocksRepeatedAttemptsInOneSession() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: [uid("asset-a")]
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        harness.provider.failNextRuntime(
            with: MLRuntimeFailure(
                category: .invalidOutputSchema,
                debugDescription: "embedding"
            ))
        await harness.lifecycle.enable(with: entryA.id)

        let failed = await waitUntil {
            if case .failed(let failure) = await harness.lifecycle.currentSnapshot().phase {
                return failure.kind == .modelLoad && !failure.isRetryable
            }
            return false
        }
        #expect(failed)
        #expect(harness.provider.attemptCount == 1)

        // Retry and condition wakes are both no-ops for the known permanent epoch. The runtime
        // must not enter an automatic or infinite model-load loop.
        await harness.lifecycle.retry()
        await harness.lifecycle.noteConditionsChanged()
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.provider.attemptCount == 1)
    }

    @Test func relaunchMayRetryAPreviouslyBlockedRuntimeEpoch() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-runtime-relaunch-\(UUID().uuidString)", isDirectory: true)
        let first = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: [uid("asset-a")],
            root: root
        )
        defer { try? FileManager.default.removeItem(at: root) }

        await first.lifecycle.start()
        first.provider.failNextRuntime(
            with: MLRuntimeFailure(
                category: .missingModel,
                debugDescription: "model artifact unavailable"
            ))
        await first.lifecycle.enable(with: entryA.id)
        #expect(
            await waitUntil {
                if case .failed(let failure) = await first.lifecycle.currentSnapshot().phase {
                    return !failure.isRetryable
                }
                return false
            })
        await first.lifecycle.shutdown()

        let relaunched = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: [uid("asset-a")],
            root: root
        )
        await relaunched.lifecycle.start()
        #expect(await waitForCompleteIndex(relaunched, total: 1))
        #expect(relaunched.provider.attemptCount == 1)
    }

    @Test func corruptStateIsReportedAndCanBePurgedWithoutStartingWork() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: [uid("asset-a")]
        )
        try Data("not-json".utf8).write(to: harness.layout.stateFileURL)

        await harness.lifecycle.start()

        #expect(await waitForStorageFailure(harness))
        #expect(harness.provider.builtCount == 0)
        #expect(harness.transport.downloadCount == 0)

        await harness.lifecycle.disableAndPurge()
        #expect(await harness.lifecycle.currentSnapshot().phase == .disabled)
        #expect(!FileManager.default.fileExists(atPath: harness.layout.rootDirectory.path))
    }

    @Test func failedSwitchJournalKeepsOldModelServing() async throws {
        let payloadA = Data("model-a-bytes".utf8)
        let payloadB = Data("model-b-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payloadA)
        let (entryB, urlB) = downloadableEntry(id: "model-b", payload: payloadB)
        let assets = (0..<4).map { uid("asset-\($0)") }
        let (harness, flaky) = try makeFlakyHarness(
            catalog: MLModelCatalog(entries: [entryA, entryB]),
            payloads: [urlA: payloadA, urlB: payloadB],
            assets: assets
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        #expect(await waitForCompleteIndex(harness, total: assets.count))

        // The switch journal cannot be written: the switch must never have happened.
        flaky.setFailing(true)
        await harness.lifecycle.select(entryB.id)

        #expect(await waitForStorageFailure(harness))
        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.selectedModelID == entryA.id)
        #expect(try flaky.load()?.selectedModelID == entryA.id)
        #expect(try flaky.load()?.pendingOperation == nil)
        // The active epoch remains queryable because an unjournaled switch retires nothing.
        let results = try await harness.lifecycle.search("anything", limit: 3)
        #expect(results.descriptor == entryA.descriptor)
        #expect(harness.storeProvider.store.count(for: entryA.descriptor) == assets.count)

        flaky.setFailing(false)
        await harness.lifecycle.retry()
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        #expect(await harness.lifecycle.currentSnapshot().selectedModelID == entryA.id)
    }

    @Test func failedPurgeJournalDeletesNothingAndRetryCompletesThePurge() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let assets = (0..<3).map { uid("asset-\($0)") }
        let (harness, flaky) = try makeFlakyHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: assets
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        #expect(await waitForCompleteIndex(harness, total: assets.count))

        flaky.setFailing(true)
        await harness.lifecycle.disableAndPurge()

        // Unjournaled purge must not delete a single file; a crash here would otherwise
        // leave an untracked half-purge.
        #expect(await waitForStorageFailure(harness))
        #expect(FileManager.default.fileExists(atPath: harness.layout.rootDirectory.path))
        #expect(FileManager.default.fileExists(atPath: harness.layout.modelDirectory(for: entryA.id).path))
        #expect(try flaky.load()?.isEnabled == true)

        flaky.setFailing(false)
        await harness.lifecycle.retry()
        #expect(await harness.lifecycle.currentSnapshot().phase == .disabled)
        #expect(!FileManager.default.fileExists(atPath: harness.layout.rootDirectory.path))
    }

    @Test func shutdownClosesStoreStopsIndexingAndRefusesNewWork() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let assets = (0..<6).map { uid("asset-\($0)") }
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: assets)
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        let sessionsBefore = harness.provider.builtCount

        await harness.lifecycle.shutdown()

        // Store handle closed (SQLite/WAL in production), and every subsequent intent is a
        // no-op: no new sessions, no downloads, queries honestly unavailable.
        #expect(harness.storeProvider.closeCount == 1)
        await harness.lifecycle.enable(with: entryA.id)
        await harness.lifecycle.retry()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(harness.provider.builtCount == sessionsBefore)
        await #expect(throws: MLSmartSearchQueryError.unavailable) {
            _ = try await harness.lifecycle.search("query", limit: 3)
        }
        // Idempotent.
        await harness.lifecycle.shutdown()
        #expect(harness.storeProvider.closeCount == 1)
    }

    @Test func shutdownAwaitsTheRunningIndexPassBeforeReturning() async throws {
        /// Session whose index pass blocks until released; stands in for CoreML mid-inference.
        final class BlockingIndexSession: MLSmartSearchSession, @unchecked Sendable {
            let descriptor: MLModelDescriptor
            private let lock = NSLock()
            private var releaseIndex: CheckedContinuation<Void, Never>?
            private var released = false
            private(set) var indexStarted = false

            init(descriptor: MLModelDescriptor) { self.descriptor = descriptor }

            func index(_ assets: [PhotoUID], observer: MLIndexPassObserver) async -> MLIndexPassOutcome {
                lock.withLock { indexStarted = true }
                await withCheckedContinuation { continuation in
                    let alreadyReleased = lock.withLock {
                        if released { return true }
                        releaseIndex = continuation
                        return false
                    }
                    if alreadyReleased { continuation.resume() }
                }
                return MLIndexPassOutcome(
                    report: MLIndexBatchReport(),
                    ranToCompletion: false,
                    newPermanentFailures: [],
                    progress: MLIndexProgress(phase: .idle, descriptor: descriptor)
                )
            }

            func release() {
                let continuation = lock.withLock {
                    released = true
                    let c = releaseIndex
                    releaseIndex = nil
                    return c
                }
                continuation?.resume()
            }

            var started: Bool { lock.withLock { indexStarted } }

            func search(_ text: String, limit: Int) async throws -> MLSearchResults {
                MLSearchResults(descriptor: descriptor, queryText: text, results: [])
            }
            func releaseMemory() async {}
            func shutdown() async {}
        }

        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: [uid("a")])
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        let blocking = BlockingIndexSession(descriptor: entryA.descriptor)
        harness.provider.sessionOverride = { _ in blocking }

        await harness.lifecycle.start()
        await harness.lifecycle.enable(with: entryA.id)
        #expect(await waitUntil { blocking.started })

        let done = Completion()
        let shutdownTask = Task { [lifecycle = harness.lifecycle] in
            await lifecycle.shutdown()
            done.mark()
        }
        // The index pass is still blocked: shutdown must not complete yet (this is exactly
        // the sign-out/purge race; deleting files under a running pass).
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!done.isDone)

        blocking.release()
        await shutdownTask.value
        #expect(done.isDone)
        #expect(harness.storeProvider.closeCount == 1)
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func mark() { lock.withLock { done = true } }
        var isDone: Bool { lock.withLock { done } }
    }

    @Test func restrictedLicenseIsUnselectableAndNeverDownloadsInRelease() async throws {
        let payload = Data("restricted-bytes".utf8)
        let url = URL(string: "https://example.test/restricted/weights.bin")!
        // Mislabeled entry: production track, restricted license, hosted plan. The license
        // must win everywhere: not listed, not auto-selected, never downloaded.
        let entry = MLModelCatalogEntry(
            id: MLModelID("model-restricted"),
            displayName: "model-restricted",
            family: "Test",
            descriptor: MLModelDescriptor(identifier: "model-restricted", version: 1, embeddingDimension: 4),
            tokenizerID: "t",
            preprocessingID: "p",
            license: MLModelLicense(
                identifier: "Test-Restricted",
                allowsRedistribution: false,
                allowsProductUse: false
            ),
            releaseTrack: .production,
            estimatedInstalledBytes: 1,
            downloadPlan: MLModelDownloadPlan(
                revision: "rev1",
                items: [
                    .init(
                        url: url,
                        artifact: MLModelArtifactSpec(
                            relativePath: "Model.mlmodelc/weights.bin", sha256: sha256(payload),
                            byteCount: Int64(payload.count)))
                ])
        )
        #expect(!entry.isDownloadable)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]),
            payloads: [url: payload],
            assets: [uid("a")],
            allowsDeveloperModels: false
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.loadModelChoices()
        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.availableModels.isEmpty)

        await harness.lifecycle.enable(with: entry.id)
        try? await Task.sleep(for: .milliseconds(100))
        let afterEnable = await harness.lifecycle.currentSnapshot()
        #expect(!afterEnable.isEnabled)
        #expect(afterEnable.selectedModelID == nil)
        #expect(harness.transport.downloadCount == 0)
    }

    @Test func unhostedProductionModelCannotEnableInRelease() async throws {
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [.tinyCLIPVit40M]),
            payloads: [:],
            assets: [uid("a")],
            allowsDeveloperModels: false
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.loadModelChoices()
        await harness.lifecycle.enable(with: MLModelCatalogEntry.tinyCLIPVit40M.id)

        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(!snapshot.isEnabled)
        #expect(snapshot.availableModels.isEmpty)
        #expect(snapshot.selectedModelID == nil)
        #expect(snapshot.phase == .disabled)
        #expect(harness.transport.downloadCount == 0)
        #expect(try harness.stateStore.load() == nil)
    }
}
