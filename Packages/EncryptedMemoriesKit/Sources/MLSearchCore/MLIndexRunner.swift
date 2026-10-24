import Foundation
import PhotosCore

/// Outcome of embedding one asset. The embedder (Apple adapter: pixels into Core ML on the
/// Neural Engine) classifies its own failures so the runner can schedule correctly:
/// permanent failures are never retried, transient ones re-enter the next pass.
public enum MLEmbeddingOutcome: Sendable {
    case embedded(ContiguousArray<Float32>)
    case permanentFailure(reason: String)
    case transientFailure
}

/// Produces an embedding for one asset. Implementations run off-main and own their pixel
/// source (decoded thumbnail) and model execution; Core never sees either.
public protocol MLAssetEmbedder: Sendable {
    func embed(uid: PhotoUID, descriptor: MLModelDescriptor) async -> MLEmbeddingOutcome
}

/// Result of one indexing pass.
public struct MLIndexPassOutcome: Sendable {
    /// Aggregated report over every processed chunk (partitions sum to processed inputs).
    public let report: MLIndexBatchReport
    /// `true` when the pass drained the plan; `false` when it stopped early (gate closed or
    /// task cancelled). A stopped pass is safe: every finished chunk is already persisted,
    /// so the next pass resumes from store state with no duplicates.
    public let ranToCompletion: Bool
    /// Assets newly persisted as permanently unindexable this pass.
    public let newPermanentFailures: Set<PhotoUID>
    /// Progress snapshot at the end of the pass.
    public let progress: MLIndexProgress

    /// Coverage derived from the pass partition. This avoids a second full membership query
    /// after the planner already classified every asset.
    public var coverage: MLIndexCoverage {
        MLIndexCoverage(
            total: progress.totalAssets,
            indexed: progress.indexed + progress.alreadyIndexed,
            permanentlyUnindexable: progress.permanentFailure
        )
    }
}

/// Serial, bounded delivery for best-effort presentation events. Producers never await UI work;
/// when a consumer lags, superseded progress is coalesced and the newest state is retained.
final class MLLatestEventSink<Value: Sendable>: @unchecked Sendable {
    private let continuation: AsyncStream<Value>.Continuation
    private let consumer: Task<Void, Never>

    init(deliver: @escaping @Sendable (Value) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Value.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.continuation = continuation
        self.consumer = Task {
            for await value in stream {
                await deliver(value)
            }
        }
    }

    func yield(_ value: Value) {
        continuation.yield(value)
    }

    deinit {
        continuation.finish()
        consumer.cancel()
    }
}

/// Best-effort visibility events for one indexing pass. Reporting is fire-and-forget and ordered:
/// presentation can lag or drop superseded progress, but it can never stall thumbnail acquisition,
/// Core ML inference, durable commits, cancellation or teardown.
public struct MLIndexPassObserver: Sendable {
    private let embeddingProduced: MLLatestEventSink<MLIndexProgress>
    private let progressUpdated: MLLatestEventSink<MLIndexProgress>

    public init(
        embeddingProduced: @escaping @Sendable (MLIndexProgress) async -> Void = { _ in },
        progressUpdated: @escaping @Sendable (MLIndexProgress) async -> Void = { _ in }
    ) {
        self.embeddingProduced = MLLatestEventSink(deliver: embeddingProduced)
        self.progressUpdated = MLLatestEventSink(deliver: progressUpdated)
    }

    func reportEmbeddingProduced(_ progress: MLIndexProgress) {
        embeddingProduced.yield(progress)
    }

    func reportProgressUpdated(_ progress: MLIndexProgress) {
        progressUpdated.yield(progress)
    }
}

/// Chunk-durable, idempotent indexing runner. Platform scheduling enters through
/// `shouldContinue`; Core never reads thermal, power or background state directly.
public actor MLIndexRunner {
    public struct Configuration: Sendable {
        /// Assets per durable commit. Smaller = finer resume granularity, more transactions.
        public var chunkSize: Int
        /// A transient native-stage failure is retried later. The retry schedule is durable and
        /// prevents a hot loop when the source image or resource budget is temporarily unavailable.
        public var retryDelay: TimeInterval
        /// Bounded retry budget before an input becomes a truthful completed-with-skips outcome.
        public var maxRetryAttempts: Int
        /// Maximum decoded assets concurrently executing a derived pipeline. Semantic embeddings
        /// keep their existing single-model loop; native adapters may opt into a measured bounded
        /// value through capability and memory policy.
        public var maximumConcurrentDerivedAssets: Int

        public init(
            chunkSize: Int = 64,
            retryDelay: TimeInterval = 120,
            maxRetryAttempts: Int = 8,
            maximumConcurrentDerivedAssets: Int = 1
        ) {
            self.chunkSize = max(1, chunkSize)
            self.retryDelay = max(1, retryDelay)
            self.maxRetryAttempts = max(1, maxRetryAttempts)
            self.maximumConcurrentDerivedAssets = max(1, maximumConcurrentDerivedAssets)
        }
    }

    private let store: any MLIndexStore
    private let embedder: any MLAssetEmbedder
    private let configuration: Configuration
    private let shouldContinue: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private var semanticQuantumPlan: SemanticQuantumPlan?

    private struct SemanticQuantumPlan {
        let libraryGeneration: UInt64
        let descriptor: MLModelDescriptor
        let totalAssets: Int
        var pending: [PhotoUID]
        var nextOffset: Int
        var deferred: [PhotoUID]
        var indexed: Int
        var permanentFailure: Int
    }

    public init(
        store: any MLIndexStore,
        embedder: any MLAssetEmbedder,
        configuration: Configuration = Configuration(),
        shouldContinue: @escaping @Sendable () -> Bool = { true },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.embedder = embedder
        self.configuration = configuration
        self.shouldContinue = shouldContinue
        self.now = now
    }

    /// Run one catch-up pass for `descriptor` over the host's full asset set.
    ///
    /// Safe to call repeatedly (idempotent), safe to interrupt (chunk-durable), safe to run
    /// after a crash (plans from store state). Returns when the plan drains or the gate closes.
    public func runPass(
        allAssets: [PhotoUID],
        descriptor: MLModelDescriptor,
        maximumAssets: Int? = nil,
        libraryGeneration: UInt64? = nil,
        passShouldContinue: @escaping @Sendable () -> Bool = { true },
        observer: MLIndexPassObserver = MLIndexPassObserver()
    ) async -> MLIndexPassOutcome {
        let usesQuantumPlan = maximumAssets != nil && libraryGeneration != nil
        var quantumPlan: SemanticQuantumPlan
        if usesQuantumPlan,
            let cached = semanticQuantumPlan,
            cached.descriptor == descriptor,
            cached.libraryGeneration == libraryGeneration
        {
            quantumPlan = cached
        } else {
            let plan: MLIndexPlan
            do {
                plan = try MLIndexPlanner.plan(
                    allAssets: allAssets,
                    descriptor: descriptor,
                    store: store
                )
            } catch {
                let progress = MLIndexProgress(
                    phase: .failed(message: "storage unavailable"),
                    descriptor: descriptor,
                    totalAssets: Set(allAssets).count
                )
                observer.reportProgressUpdated(progress)
                return MLIndexPassOutcome(
                    report: MLIndexBatchReport(),
                    ranToCompletion: false,
                    newPermanentFailures: [],
                    progress: progress
                )
            }
            quantumPlan = SemanticQuantumPlan(
                libraryGeneration: libraryGeneration ?? 0,
                descriptor: descriptor,
                totalAssets: plan.totalAssets,
                pending: plan.toIndex,
                nextOffset: 0,
                deferred: [],
                indexed: plan.skippedAlreadyIndexed.count,
                permanentFailure: plan.skippedPermanentFailure.count
            )
        }
        if quantumPlan.nextOffset == quantumPlan.pending.count,
            !quantumPlan.deferred.isEmpty
        {
            quantumPlan.pending = quantumPlan.deferred
            quantumPlan.nextOffset = 0
            quantumPlan.deferred.removeAll(keepingCapacity: true)
        }
        let pendingCount = quantumPlan.pending.count - quantumPlan.nextOffset

        var progress = MLIndexProgress(
            phase: pendingCount == 0 ? .completed : .indexing,
            descriptor: descriptor,
            totalAssets: quantumPlan.totalAssets,
            alreadyIndexed: quantumPlan.indexed,
            permanentFailure: quantumPlan.permanentFailure
        )
        observer.reportProgressUpdated(progress)

        var aggregate = MLIndexBatchReport()
        var newPermanent: Set<PhotoUID> = []
        let passLimit = min(
            pendingCount,
            maximumAssets.map { max(1, $0) } ?? pendingCount
        )
        var completed = passLimit == pendingCount && quantumPlan.deferred.isEmpty
        var chunkStart = 0
        var processedFromPlan = 0
        var retryUIDs: [PhotoUID] = []
        var reportedEmbeddingActivity = false

        while chunkStart < passLimit {
            let chunkEnd = min(chunkStart + configuration.chunkSize, passLimit)
            let absoluteStart = quantumPlan.nextOffset + chunkStart
            let absoluteEnd = quantumPlan.nextOffset + chunkEnd
            let chunk = quantumPlan.pending[absoluteStart..<absoluteEnd]
            chunkStart = chunkEnd
            var records: [MLEmbeddingRecord] = []
            var failureRecords: [MLIndexFailureRecord] = []
            var chunkPermanentUIDs: Set<PhotoUID> = []
            records.reserveCapacity(chunk.count)
            failureRecords.reserveCapacity(chunk.count)
            var chunkPermanent = 0
            var chunkTransient = 0
            var chunkTransientUIDs: [PhotoUID] = []
            var processedCount = 0
            var stopAfterCommit = false

            for uid in chunk {
                guard shouldContinue(), passShouldContinue(), !Task.isCancelled else {
                    completed = false
                    stopAfterCommit = true
                    break
                }

                let outcome = await embedder.embed(uid: uid, descriptor: descriptor)
                processedCount += 1
                switch outcome {
                case .embedded(let vector):
                    guard vector.count == descriptor.embeddingDimension,
                        let normalized = MLVectorNormalization.normalized(vector)
                    else {
                        chunkPermanentUIDs.insert(uid)
                        chunkPermanent += 1
                        failureRecords.append(
                            MLIndexFailureRecord(
                                uid: uid,
                                descriptor: descriptor,
                                kind: .permanent,
                                reason: "invalid embedding",
                                attempts: 1,
                                updatedAt: now()
                            ))
                        continue
                    }
                    records.append(MLEmbeddingRecord(uid: uid, descriptor: descriptor, vector: normalized))
                    if !reportedEmbeddingActivity {
                        reportedEmbeddingActivity = true
                        observer.reportEmbeddingProduced(progress)
                    }
                case .permanentFailure(let reason):
                    chunkPermanentUIDs.insert(uid)
                    chunkPermanent += 1
                    failureRecords.append(
                        MLIndexFailureRecord(
                            uid: uid,
                            descriptor: descriptor,
                            kind: .permanent,
                            reason: reason,
                            attempts: 1,
                            updatedAt: now()
                        ))
                case .transientFailure:
                    chunkTransient += 1
                    chunkTransientUIDs.append(uid)
                // Cache misses and temporary resource pressure are expected during the
                // initial crawl. They stay pending in the pass result; persisting them
                // would turn every retry into a large write-only SQLite workload.
                }
                // Cancellation may arrive while CoreML is executing. Persist this completed
                // asset, then return without starting another inference.
                if Task.isCancelled {
                    completed = false
                    stopAfterCommit = true
                    break
                }
            }

            guard processedCount > 0 else { break }
            processedFromPlan += processedCount

            // Durable commit before the next chunk: this is the resume point.
            #if ENCRYPTED_MEMORIES_UPGRADE_TEST
                UpgradeTestProbe.checkpoint("index.beforeCommit")
            #endif
            let stored = store.upsert(records)
            #if ENCRYPTED_MEMORIES_UPGRADE_TEST
                UpgradeTestProbe.checkpoint("index.afterCommit")
            #endif

            let failuresPersisted = store.recordFailures(failureRecords)
            let chunkReport = MLIndexBatchReport(
                total: processedCount,
                indexed: stored.indexed,
                skippedAlreadyIndexed: stored.skippedAlreadyIndexed,
                permanentFailure: (failuresPersisted ? chunkPermanent : 0) + stored.permanentFailure,
                transientFailure: chunkTransient
                    + (failuresPersisted ? 0 : failureRecords.count)
                    + stored.transientFailure
            )
            aggregate = aggregate.merge(chunkReport)
            progress.apply(chunkReport)
            observer.reportProgressUpdated(progress)

            // Store-layer transient failures invalidate the cached bounded plan. They are
            // distinct from an embedder transient miss, which remains eligible for ordinary
            // retry scheduling below.
            guard stored.transientFailure == 0, failuresPersisted else {
                completed = false
                semanticQuantumPlan = nil
                progress.phase = .failed(message: "storage unavailable")
                observer.reportProgressUpdated(progress)
                return MLIndexPassOutcome(
                    report: aggregate,
                    ranToCompletion: false,
                    newPermanentFailures: newPermanent,
                    progress: progress
                )
            }
            newPermanent.formUnion(chunkPermanentUIDs)
            retryUIDs.append(contentsOf: chunkTransientUIDs)

            if stopAfterCommit { break }
        }

        if usesQuantumPlan {
            quantumPlan.nextOffset += processedFromPlan
            quantumPlan.deferred.append(contentsOf: retryUIDs)
            quantumPlan.indexed += aggregate.indexed + aggregate.skippedAlreadyIndexed
            quantumPlan.permanentFailure += aggregate.permanentFailure
            semanticQuantumPlan = progress.isComplete ? nil : quantumPlan
        } else {
            semanticQuantumPlan = nil
        }

        if progress.phase == .indexing {
            // Honest state: the pass ended without epoch completion (gate stop, cancellation,
            // or transient failures pending retry). Never claim .completed here; the next
            // pass resumes from store state.
            progress.phase = .idle
        }
        observer.reportProgressUpdated(progress)

        return MLIndexPassOutcome(
            report: aggregate,
            ranToCompletion: completed,
            newPermanentFailures: newPermanent,
            progress: progress
        )
    }

    /// Shared bounded runner for non-vector ML stages. It uses the same configuration and resource
    /// gate as semantic indexing, while each artifact remains independently durable and purgeable.
    public static func runDerivedPass(
        key: MLPipelineExecutionKey,
        store: any MLDerivedPipelineStore,
        executor: any MLDerivedPipelineExecutor,
        configuration: Configuration = Configuration(),
        maximumAnalysisPlans: Int? = nil,
        shouldContinue: @escaping @Sendable () -> Bool = { true },
        now: @escaping @Sendable () -> Date = { Date() },
        observer: MLDerivedPipelineObserver = MLDerivedPipelineObserver()
    ) async -> MLDerivedPipelinePassOutcome {
        var progress: MLDerivedPipelineProgress
        do {
            progress = try store.progress(for: key)
        } catch {
            return MLDerivedPipelinePassOutcome(
                reason: .storageFailure,
                progress: emptyDerivedProgress()
            )
        }
        observer.report(progress)
        var remainingAnalysisPlans = maximumAnalysisPlans.map { max(1, $0) }

        while shouldContinue(), !Task.isCancelled {
            let currentTime = now()
            let work: [MLDerivedPipelineWorkItem]
            do {
                work = try store.nextWorkBatch(
                    for: key,
                    limit: configuration.chunkSize * max(1, key.artifacts.count),
                    now: currentTime
                )
            } catch {
                return MLDerivedPipelinePassOutcome(reason: .storageFailure, progress: progress)
            }
            guard !work.isEmpty else {
                do {
                    progress = try store.progress(for: key)
                } catch {
                    return MLDerivedPipelinePassOutcome(reason: .storageFailure, progress: progress)
                }
                return MLDerivedPipelinePassOutcome(
                    reason: progress.isComplete ? .drained : .retryPending,
                    progress: progress
                )
            }

            let allPlans = makeAnalysisPlans(work)
            let planLimit = min(
                allPlans.count,
                remainingAnalysisPlans ?? allPlans.count
            )
            let plans = Array(allPlans.prefix(planLimit))
            var committedResults: [MLPipelineStageResult] = []
            committedResults.reserveCapacity(work.count)
            var stopReason: MLDerivedPipelineStopReason?
            var deferredWorkSeen = false

            var planOffset = 0
            while planOffset < plans.count {
                guard shouldContinue(), !Task.isCancelled else {
                    stopReason = Task.isCancelled ? .cancelled : .policySuspended
                    break
                }
                let waveEnd = min(
                    planOffset + configuration.maximumConcurrentDerivedAssets,
                    plans.count
                )
                let wave = Array(plans[planOffset..<waveEnd])
                planOffset = waveEnd
                let returnedByPlan = await execute(
                    wave,
                    with: executor
                )

                for (plan, returned) in zip(wave, returnedByPlan) {
                    let byArtifact = Dictionary(
                        returned.map { ($0.workItem.artifact, $0) },
                        uniquingKeysWith: { first, _ in first }
                    )

                    for item in plan.workItems {
                        var result =
                            byArtifact[item.artifact]
                            ?? MLPipelineStageResult(
                                workItem: item,
                                outcome: .retryableFailure(reason: .invalidExecutorResult, retryAfter: nil)
                            )
                        if result.workItem.asset != item.asset {
                            result = MLPipelineStageResult(
                                workItem: item,
                                outcome: .retryableFailure(reason: .invalidExecutorResult, retryAfter: nil)
                            )
                        }
                        result = normalizedResult(
                            result,
                            item: item,
                            configuration: configuration,
                            now: currentTime
                        )
                        switch result.outcome {
                        case .cancelled:
                            stopReason = .cancelled
                        case .suspended:
                            stopReason = .policySuspended
                        case .deferred:
                            deferredWorkSeen = true
                            committedResults.append(result)
                        default:
                            committedResults.append(result)
                        }
                    }
                }
                if stopReason != nil { break }
            }

            if !committedResults.isEmpty {
                guard store.commit(committedResults, for: key, now: currentTime) else {
                    progress = (try? store.progress(for: key)) ?? progress
                    return MLDerivedPipelinePassOutcome(reason: .storageFailure, progress: progress)
                }
                do {
                    progress = try store.progress(for: key)
                } catch {
                    return MLDerivedPipelinePassOutcome(reason: .storageFailure, progress: progress)
                }
                observer.report(progress)
            }
            if let stopReason {
                return MLDerivedPipelinePassOutcome(reason: stopReason, progress: progress)
            }
            if deferredWorkSeen {
                // Nonresident sources must not stall older queued assets behind their retry slot.
                let hasUntouchedWork = progress.pending > progress.retryPending
                return MLDerivedPipelinePassOutcome(
                    reason: hasUntouchedWork ? .workQuantumCompleted : .retryPending,
                    progress: progress
                )
            }
            if let remaining = remainingAnalysisPlans {
                remainingAnalysisPlans = remaining - plans.count
                if remainingAnalysisPlans == 0, !progress.isComplete {
                    return MLDerivedPipelinePassOutcome(
                        reason: .workQuantumCompleted,
                        progress: progress
                    )
                }
            }
            if planLimit < allPlans.count {
                return MLDerivedPipelinePassOutcome(
                    reason: .workQuantumCompleted,
                    progress: progress
                )
            }
        }

        do {
            progress = try store.progress(for: key)
        } catch {
            return MLDerivedPipelinePassOutcome(
                reason: Task.isCancelled ? .cancelled : .storageFailure,
                progress: progress
            )
        }
        return MLDerivedPipelinePassOutcome(
            reason: Task.isCancelled ? .cancelled : .policySuspended,
            progress: progress
        )
    }

    private static func emptyDerivedProgress() -> MLDerivedPipelineProgress {
        MLDerivedPipelineProgress(
            total: 0,
            completed: 0,
            skipped: 0,
            permanentFailure: 0,
            retryPending: 0,
            generation: 0
        )
    }

    private static func makeAnalysisPlans(_ work: [MLDerivedPipelineWorkItem]) -> [MLAssetAnalysisPlan] {
        var grouped: [MLPipelineAssetRevision: [MLDerivedPipelineWorkItem]] = [:]
        var order: [MLPipelineAssetRevision] = []
        for item in work {
            if grouped[item.asset] == nil { order.append(item.asset) }
            grouped[item.asset, default: []].append(item)
        }
        return order.compactMap { asset in
            guard let workItems = grouped[asset] else { return nil }
            return try? MLAssetAnalysisPlan(asset: asset, workItems: workItems)
        }
    }

    private static func execute(
        _ plans: [MLAssetAnalysisPlan],
        with executor: any MLDerivedPipelineExecutor
    ) async -> [[MLPipelineStageResult]] {
        guard plans.count > 1 else {
            guard let plan = plans.first else { return [] }
            return [await executor.execute(plan)]
        }

        return await withTaskGroup(
            of: (Int, [MLPipelineStageResult]).self,
            returning: [[MLPipelineStageResult]].self
        ) { group in
            for (index, plan) in plans.enumerated() {
                group.addTask {
                    (index, await executor.execute(plan))
                }
            }
            var ordered = Array(repeating: [MLPipelineStageResult](), count: plans.count)
            for await (index, results) in group {
                ordered[index] = results
            }
            return ordered
        }
    }

    private static func normalizedResult(
        _ result: MLPipelineStageResult,
        item: MLDerivedPipelineWorkItem,
        configuration: Configuration,
        now: Date
    ) -> MLPipelineStageResult {
        if case .deferred(let reason, let requestedRetry) = result.outcome {
            return MLPipelineStageResult(
                workItem: item,
                outcome: .deferred(
                    reason: reason,
                    retryAfter: requestedRetry ?? now.addingTimeInterval(configuration.retryDelay)
                )
            )
        }
        guard case .retryableFailure(let reason, let requestedRetry) = result.outcome else {
            return result
        }
        if item.attempts + 1 >= configuration.maxRetryAttempts {
            return MLPipelineStageResult(
                workItem: item,
                outcome: .permanentInputFailure(reason: .retryLimitReached)
            )
        }
        return MLPipelineStageResult(
            workItem: item,
            outcome: .retryableFailure(
                reason: reason,
                retryAfter: requestedRetry ?? now.addingTimeInterval(configuration.retryDelay)
            )
        )
    }
}
