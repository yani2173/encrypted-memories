import Foundation
import PhotosCore

/// The universal backup sync executor: drains the persistent `UploadBackupSyncQueueStore` through
/// the shared dedupe pipeline and upload backend. one implementation for every platform - adapters
/// contribute only a `BackupResourceResolving` (how to rematerialize a source) and throttle inputs.
///
/// Safety contract (the reason this actor exists):
/// - every state transition is persisted before the expensive/irreversible work it describes,
/// - a completed upload is recorded in the identity manifest before the queue row turns terminal,
///   so a crash in between re-resolves to a remote duplicate instead of a second upload,
/// - stale active rows from a crashed run are requeued on start (`requeueStaleActive`),
/// - trashed/deleted-remote duplicates and vanished sources land in their own explicit states and
///   are never counted as backed up,
/// - a remote draft parks the row as `.blockedByDraft` and re-checks with capped backoff - it can
///   never surface as success.
public actor BackupSyncRunner {
    private enum PrimaryScopedOutcome: Sendable {
        case uploaded(PhotoUID)
        case decision(UploadPreflightResult)
    }

    public enum DrainMode: Sendable, Equatable {
        /// Keep the caller alive across persisted retry dates. Used by bounded, one-shot backup
        /// operations that own their full retry lifecycle.
        case waitForScheduledRetries
        /// Process only work eligible now, then return. Used by the Photo Library reconcile loop so
        /// one delayed row cannot hide newly enqueued work or hold an OS execution window open.
        case eligibleOnly
    }

    public struct Configuration: Sendable, Equatable {
        /// Queue rows fetched per scheduling round (workers take at most the throttle limit).
        public var batchSize: Int
        /// Rows active before (start − grace) are treated as crash leftovers. 0 = every active
        /// row at start is stale, which is correct while a single runner owns the queue.
        public var staleActiveGrace: TimeInterval
        /// Poll interval while the throttle reports "pause" (thermal critical etc.).
        public var pausedPollInterval: TimeInterval
        /// Maximum time an upload may emit no backend progress before it is cancelled and retried.
        /// Total upload duration is unlimited while progress continues.
        public var uploadStallTimeout: TimeInterval
        /// Monotonic watchdog cadence. Kept coarse in production to avoid needless wakeups.
        public var uploadStallPollInterval: TimeInterval
        public var retry: BackupRetryPolicy
        public var throttle: BackupThrottlePolicy
        /// How often a one-shot drain (`waitForScheduledRetries`, such as an album backup the user waits for) checks
        /// a photo the camera still processes again. Library passes check it once, at the end of the camera window.
        public var oneShotSourceRecheckInterval: TimeInterval

        public init(
            batchSize: Int = 32,
            staleActiveGrace: TimeInterval = 0,
            pausedPollInterval: TimeInterval = 30,
            uploadStallTimeout: TimeInterval = 180,
            uploadStallPollInterval: TimeInterval = 5,
            retry: BackupRetryPolicy = BackupRetryPolicy(),
            throttle: BackupThrottlePolicy = BackupThrottlePolicy(),
            oneShotSourceRecheckInterval: TimeInterval = 30
        ) {
            self.batchSize = max(1, batchSize)
            self.staleActiveGrace = max(0, staleActiveGrace)
            self.pausedPollInterval = max(0.01, pausedPollInterval)
            self.uploadStallTimeout = max(0.01, uploadStallTimeout)
            self.uploadStallPollInterval = max(0.01, min(uploadStallPollInterval, uploadStallTimeout))
            self.retry = retry
            self.throttle = throttle
            self.oneShotSourceRecheckInterval = max(0, oneShotSourceRecheckInterval)
        }
    }

    private let queue: any UploadBackupSyncQueueStore
    private let preflight: UploadBackupPreflightIndex
    private let resolver: any BackupResourceResolving
    /// Deliberately non-optional: automatic backup without duplicate detection would risk double
    /// uploads, so a missing manifest must fail composition, not silently degrade.
    private let identityResolver: any UploadIdentityResolving
    private let uploader: any PhotoUploading
    /// Marks an existing main photo as a series when only its missing members upload. Nil for sources
    /// that never produce a series (folder backup).
    private let tagAdder: (any PhotoTagAdding)?
    /// Replaces the earlier upload of an edited photo-library photo. Nil for sources without edits (folder backup).
    private let editReplacement: EditedPhotoReplacement?
    private let resourceCoordinator: LibraryResourceCoordinator
    private let configuration: Configuration
    private let throttleInputs: @Sendable () -> BackupThrottleInputs
    private let clock: any BackupSchedulerClock
    private let now: @Sendable () -> Date

    private var isRunning = false
    private var drainMode: DrainMode = .waitForScheduledRetries
    private var deletionStateInvalidated = false
    private var stopRequested = false
    /// Consecutive items that could not even reserve disk space since the last one that did.
    /// Reset to 0 the moment any export succeeds; when it reaches a full wave the drain ends the
    /// pass (rows stay runnable) instead of spinning against a genuinely full volume.
    private var resourcePressureStreak = 0
    /// Consecutive transport-level network failures since the last successful settle. Subtracted from
    /// the throttle's concurrency so the drain backs off a marginal/looping connection instead of
    /// hammering it with parallel requests, and ramps back up as items succeed. Capped so it can
    /// never wedge the drain below one in-flight item.
    private var networkErrorStreak = 0
    private static let maxNetworkBackoff = 5
    /// Cancellation tokens of uploads currently in flight, so source removal can find transfers.
    private var inFlightTokens: [String: UUID] = [:]
    /// Join handles retain the unstructured upload task until native cancellation and upload
    /// settlement both finish. They also deduplicate every cancellation request for that upload.
    private var inFlightJoins: [UUID: BackupUploadJoin] = [:]
    private var inFlightNames: [String: String] = [:]
    /// Sources removed from the local backup set while this actor was suspended in resolver or
    /// upload work. Their callbacks must not recreate a queue row after catalog removal.
    private var removedSources: Set<String> = []
    /// Ephemeral, quantized transfer liveness. Queue durability remains item based; block callbacks
    /// update this in-memory mirror only, so large videos visibly advance without per-block SQLite writes.
    private struct ActiveTransfer {
        let generation: UUID
        var totalBytes: Int64
        var byteFraction: Double
        var itemBaseFraction: Double
        var itemFractionWeight: Double
    }
    private var activeTransfers: [String: ActiveTransfer] = [:]
    /// Stage high-water marks remain until the item settles, so identity, materialization, upload, and
    /// primary-to-secondary handoffs cannot make continued-processing progress go backwards.
    private struct ActiveExecution {
        let generation: UUID
        let source: UploadSourceIdentity
        let revision: UploadBackupRevision
        var preparationFraction: Double
        var uploadFraction: Double
        /// The last ring step sent to `events`, so a source reports at most 21 progress events.
        var reportedStep: Int?
    }
    private var activeExecutions: [String: ActiveExecution] = [:]
    /// A remote-index refresh happens before any queue item can be claimed. It contributes less than
    /// one item and is handed off to the first terminal row, keeping BGTask progress live and bounded.
    private var remoteIndexExecutionFraction: Double = 0
    private var remoteIndexPreparationGeneration: UUID?

    private var progress = BackupSyncProgress()
    private var onProgress: (@Sendable (BackupSyncProgress) -> Void)?
    /// Durable per-source events for the pending grid: duplicate-check evidence, handoffs, exclusion and
    /// ring progress.
    private let events: (any BackupItemEventSink)?

    public init(
        queue: any UploadBackupSyncQueueStore,
        preflight: UploadBackupPreflightIndex,
        resolver: any BackupResourceResolving,
        identityResolver: any UploadIdentityResolving,
        uploader: any PhotoUploading,
        tagAdder: (any PhotoTagAdding)? = nil,
        editReplacement: EditedPhotoReplacement? = nil,
        resourceCoordinator: LibraryResourceCoordinator = .shared,
        configuration: Configuration = Configuration(),
        throttleInputs: @Sendable @escaping () -> BackupThrottleInputs = { .unconstrained },
        clock: any BackupSchedulerClock = BackupContinuousClock(),
        events: (any BackupItemEventSink)? = nil,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.queue = queue
        self.events = events
        self.preflight = preflight
        self.resolver = resolver
        self.identityResolver = identityResolver
        self.uploader = uploader
        self.tagAdder = tagAdder
        self.editReplacement = editReplacement
        self.resourceCoordinator = resourceCoordinator
        self.configuration = configuration
        self.throttleInputs = throttleInputs
        self.clock = clock
        self.now = now
    }

    public func setOnProgress(_ handler: (@Sendable (BackupSyncProgress) -> Void)?) {
        onProgress = handler
        emitProgress()
    }

    public func currentProgress() -> BackupSyncProgress {
        progress
    }

    /// Queue health is part of the runner contract: callers must never treat an empty result from a
    /// failed SQLite read as a drained backup.
    public func isQueueOperational() -> Bool {
        queue.isOperational()
    }

    /// User-initiated retry contract. Eligibility changes and remote-cache invalidation stay together
    /// so a parked draft is checked against the server now instead of replaying a cached answer.
    @discardableResult
    public func makeRetryableWorkEligibleNow() async -> Int {
        let changed = queue.makeRetryableWorkEligible(updatedAt: now())
        let hadRemoteIndexIssue = queue.runtimeIssue(for: .remoteIndexPreparation) != nil
        let clearedRemoteIndexIssue =
            !hadRemoteIndexIssue
            || queue.setRuntimeIssue(nil, for: .remoteIndexPreparation)
        await identityResolver.invalidateCachedRemoteState()
        return changed + (hadRemoteIndexIssue && clearedRemoteIndexIssue ? 1 : 0)
    }

    /// Invalidates the remote view without changing queue eligibility or runtime backoff.
    public func invalidateRemoteStateForUserRetry() async {
        await identityResolver.invalidateCachedRemoteState()
    }

    /// Ask the current pass to wind down: no new work starts, in-flight uploads are cancelled,
    /// and every touched row is reverted to a runnable state for the next pass after settlement.
    public func stop() async {
        stopRequested = true
        let joins = Array(inFlightJoins.values)
        await withTaskGroup(of: Void.self) { group in
            for join in joins {
                group.addTask { await join.cancelAndJoin() }
            }
        }
    }

    /// Applies a live PhotoKit deletion to both durable and in-flight work. Cancellation is best
    /// effort once the backend has started committing, but the local deletion never becomes a
    /// failed backup row and no completion callback can resurrect it.
    @discardableResult
    public func removePhotoLibraryAssets(_ identifiers: [String]) async -> Int {
        await removeSources(kind: .photoLibraryAsset, identifiers: identifiers)
    }

    /// Removes sources from durable and in-flight work, for a local deletion or an exclusion from backup.
    @discardableResult
    public func removeSources(kind: UploadSourceIdentity.Kind, identifiers: [String]) async -> Int {
        let identifiers = Array(Set(identifiers))
        guard !identifiers.isEmpty else { return 0 }
        let sourceKeys = Set(
            identifiers.map {
                Self.sourceKey(kind: kind, identifier: $0)
            })
        removedSources.formUnion(sourceKeys)

        let tokens = inFlightTokens.compactMap { key, token in
            sourceKeys.contains(where: { key.hasPrefix($0 + "|") }) ? token : nil
        }
        let joins = tokens.compactMap { inFlightJoins[$0] }
        // Make the local deletion authoritative before awaiting native cancellation. The actor can
        // re-enter while a join is suspended; leaving the row until afterwards lets the active drain
        // return one stale item even though this removal already tombstoned every completion callback.
        let removed = queue.removeSources(kind: kind, identifiers: identifiers)
        refreshProgressFromQueue()
        emitProgress()
        await withTaskGroup(of: Void.self) { group in
            for join in joins {
                group.addTask { await join.cancelAndJoin() }
            }
        }
        return removed
    }

    /// Runs crash recovery, then drains the queue according to `mode`. Parked `blockedByDraft` rows
    /// get one due-based re-check per call. A second concurrent call returns the live snapshot.
    @discardableResult
    public func runUntilDrained(
        mode: DrainMode = .waitForScheduledRetries,
        workIntent: LibraryWorkIntent = .automatic
    ) async -> BackupSyncProgress {
        guard !isRunning else { return progress }
        guard queue.isOperational() else {
            progress.isRunning = false
            progress.currentItemName = nil
            emitProgress()
            return progress
        }
        isRunning = true
        deletionStateInvalidated = false
        drainMode = mode
        stopRequested = false
        removedSources = []
        activeTransfers = [:]
        activeExecutions = [:]
        remoteIndexExecutionFraction = 0
        remoteIndexPreparationGeneration = nil
        resourcePressureStreak = 0
        defer {
            remoteIndexPreparationGeneration = nil
            remoteIndexExecutionFraction = 0
            publishActiveExecutionProgress(emit: false)
            isRunning = false
            progress.isRunning = false
            progress.currentItemName = nil
            removedSources = []
            emitProgress()
        }

        // Crash recovery first: anything still marked active predates this run and must become
        // runnable again before this runner atomically claims new work.
        queue.requeueStaleActive(before: now().addingTimeInterval(-configuration.staleActiveGrace), updatedAt: now())
        guard queue.isOperational() else { return progress }
        await requeueDueBlockedRows()
        guard queue.isOperational() else { return progress }

        progress = BackupSyncProgress(summary: queue.summary(), isRunning: true)
        progress.remoteIndexPreparationIssue = queue.runtimeIssue(for: .remoteIndexPreparation)
        progress.remoteIndexPreparationFailed = progress.remoteIndexPreparationIssue != nil
        guard queue.isOperational() else { return progress }
        emitProgress()

        if mode == .eligibleOnly {
            guard let nextRunnableDate = queue.nextRunnableDate(), nextRunnableDate <= now() else {
                progress.isRunning = false
                return progress
            }
            guard configuration.throttle.maxConcurrentItems(for: throttleInputs()) > 0 else {
                progress.isPausedByPolicy = true
                progress.isRunning = false
                return progress
            }
        }

        let remoteIndexGeneration = UUID()
        remoteIndexPreparationGeneration = remoteIndexGeneration
        do {
            try await identityResolver.prepareRemoteIndex { [weak self] value in
                await self?.setRemoteIndexPreparation(value, generation: remoteIndexGeneration)
            }
            progress.remoteContentIndexHealth = try await identityResolver.remoteContentIndexHealth()
            finishRemoteIndexPreparation(generation: remoteIndexGeneration)
            progress.remoteIndexPreparationFailed = false
            progress.remoteIndexPreparationIssue = nil
            guard queue.setRuntimeIssue(nil, for: .remoteIndexPreparation) else {
                progress.isRunning = false
                emitProgress()
                return progress
            }
            emitProgress()
        } catch is CancellationError {
            cancelRemoteIndexPreparation(generation: remoteIndexGeneration)
            return progress
        } catch {
            cancelRemoteIndexPreparation(generation: remoteIndexGeneration)
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let issue = automaticRetryIssue(
                kind: Self.issueKind(for: error),
                detail: message,
                previous: queue.runtimeIssue(for: .remoteIndexPreparation)
            )
            guard queue.setRuntimeIssue(issue, for: .remoteIndexPreparation) else {
                stopRequested = true
                return progress
            }
            progress.remoteIndexPreparationFailed = true
            progress.remoteIndexPreparationIssue = issue
            progress.isRunning = false
            emitProgress()
            return progress
        }

        // Warm the dedup pipeline's remote cache for the first batch so per-item resolves are cache
        // hits (see primeRunnableLookahead). Re-warmed periodically as the queue drains.
        await primeRunnableLookahead()
        guard queue.isOperational() else { return progress }
        var claimedSincePrime = 0

        // Up to `limit` items run at once, and a finished item frees its slot for the next one at once: one long
        // upload, such as a video, never holds back the items behind it. Rows are claimed only for free slots, and
        // the loop ends only when no item runs, so every claimed row keeps its worker.
        await withTaskGroup(of: String.self) { group in
            var running = 0
            // Two revisions of one photo (a preliminary camera version and the finished one) run one after the
            // other: both read the current file, and the second then finds it backed up instead of uploading
            // the same bytes at the same time. A claimed row of a photo that runs now waits here for its turn.
            var busySources: Set<String> = []
            var waitingBehindSource: [String: [UploadBackupSyncQueueEntry]] = [:]

            drain: while true {
                // A whole batch that could not reserve disk space means the volume is full, not busy.
                // Stop draining and leave the rows runnable: the next pass retries once space frees,
                // and the status reads "waiting" (never a permanent, unactionable failure).
                let mayClaim =
                    !stopRequested && !Task.isCancelled && resourcePressureStreak < configuration.batchSize
                if mayClaim {
                    if queue.isOperational() {
                        await requeueDueBlockedRows()
                        if !queue.isOperational() { stopRequested = true }
                    } else {
                        stopRequested = true
                    }
                }
                if mayClaim, !stopRequested {
                    let throttleSnapshot = throttleInputs()
                    let policyLimit = configuration.throttle.maxConcurrentItems(for: throttleSnapshot)
                    // Back off concurrency while a marginal connection is dropping requests, but never below 1
                    // (never stall - a single in-flight item keeps making progress and probes recovery).
                    let limit = policyLimit == 0 ? 0 : max(1, policyLimit - networkErrorStreak)
                    if limit == 0 {
                        // Items that already run finish first; the pause starts once none runs.
                        if running == 0 {
                            if !progress.isPausedByPolicy {
                                progress.isPausedByPolicy = true
                                emitProgress()
                            }
                            if mode == .eligibleOnly { break drain }
                            do {
                                try await clock.sleep(for: configuration.pausedPollInterval)
                            } catch {
                                break drain
                            }
                            continue drain
                        }
                    } else {
                        if progress.isPausedByPolicy {
                            progress.isPausedByPolicy = false
                            emitProgress()
                        }

                        // Re-warm the dedup cache once the current lookahead is largely consumed. prime()
                        // invalidates the previous batch first, so we do this on a cadence (not every claim) to
                        // avoid dropping still-useful cached state mid-drain.
                        if claimedSincePrime >= Self.claimsPerPrime {
                            await primeRunnableLookahead()
                            claimedSincePrime = 0
                        }

                        if running < limit {
                            let claimed = nextEligibleWave(limit: limit - running)
                            claimedSincePrime += claimed.count
                            for entry in claimed {
                                let key = Self.sourceKey(kind: entry.source.kind, identifier: entry.source.identifier)
                                if busySources.contains(key) {
                                    waitingBehindSource[key, default: []].append(entry)
                                    continue
                                }
                                busySources.insert(key)
                                running += 1
                                group.addTask {
                                    await self.process(entry, workIntent: workIntent)
                                    return key
                                }
                            }
                            if claimed.isEmpty, running == 0 {
                                guard queue.isOperational() else {
                                    stopRequested = true
                                    break drain
                                }
                                guard let wait = shortestPendingWait() else {
                                    if !queue.isOperational() { stopRequested = true }
                                    break drain
                                }
                                if mode == .eligibleOnly { break drain }
                                // Only an item waiting for Proton storage waits longer than any regular retry. A
                                // one-shot drain the user waits for ends then instead of sleeping for hours.
                                if wait > longestRegularRetryWait { break drain }
                                do {
                                    try await clock.sleep(for: wait)
                                } catch {
                                    break drain
                                }
                                continue drain
                            }
                        }
                    }
                }

                // Wait for the next item to finish. Its slot goes to a waiting revision of the same photo first.
                guard running > 0, let key = await group.next() else { break drain }
                running -= 1
                if var waiting = waitingBehindSource[key], !waiting.isEmpty {
                    let next = waiting.removeFirst()
                    waitingBehindSource[key] = waiting.isEmpty ? nil : waiting
                    running += 1
                    group.addTask {
                        await self.process(next, workIntent: workIntent)
                        return key
                    }
                } else {
                    busySources.remove(key)
                }
            }
        }

        // Truth re-sync from the store: incremental counters were exact (single writer), but the
        // final snapshot should come from the durable state regardless.
        if queue.isOperational() {
            let wasPausedByPolicy = progress.isPausedByPolicy
            progress = BackupSyncProgress(summary: queue.summary(), isRunning: false)
            progress.isPausedByPolicy = wasPausedByPolicy
        } else {
            // Preserve the last trustworthy counters. The controller exposes the unavailable store;
            // replacing this with an empty summary would falsely look like a completed backup.
            progress.isRunning = false
        }
        emitProgress()
        return progress
    }

    // MARK: - Scheduling

    private func setRemoteIndexPreparation(
        _ value: UploadRemoteIndexPreparationProgress,
        generation: UUID
    ) {
        guard remoteIndexPreparationGeneration == generation else { return }
        progress.remoteIndexPreparation = value
        progress.remoteIndexPreparationFailed = false
        progress.remoteIndexPreparationIssue = nil
        remoteIndexExecutionFraction = max(
            remoteIndexExecutionFraction,
            Self.remoteIndexItemEquivalent(value)
        )
        publishActiveExecutionProgress(emit: false)
        emitProgress()
    }

    private func finishRemoteIndexPreparation(generation: UUID) {
        guard remoteIndexPreparationGeneration == generation else { return }
        remoteIndexPreparationGeneration = nil
        progress.remoteIndexPreparation = .init(phase: .ready)
        remoteIndexExecutionFraction = max(remoteIndexExecutionFraction, 0.249)
        publishActiveExecutionProgress(emit: false)
    }

    private func cancelRemoteIndexPreparation(generation: UUID) {
        guard remoteIndexPreparationGeneration == generation else { return }
        remoteIndexPreparationGeneration = nil
        remoteIndexExecutionFraction = 0
        publishActiveExecutionProgress(emit: false)
    }

    private func nextEligibleWave(limit: Int) -> [UploadBackupSyncQueueEntry] {
        let claimLimit = min(configuration.batchSize, max(1, limit))
        // Eligibility is persisted in `updatedAt` and enforced inside the same transaction that
        // moves rows to `checking`. Never filter after claiming: a discarded claim has no worker
        // and would remain falsely active until crash recovery.
        return queue.claimRunnable(limit: claimLimit, claimedAt: now())
    }

    static func supportEventKind(of outcome: EditedPhotoReplacement.Outcome) -> SupportEventTrail.Kind {
        switch outcome {
        case .replaced: .editReplaced
        case .waiting: .editWaiting
        case .replacementGone: .editReplacementGone
        case .kept: .editKept
        }
    }

    /// The wait before an edit checks again whether it can replace its earlier upload. Each check reads and hashes
    /// the photo again, which is expensive for a video, so the wait doubles from `first` up to six hours. The first
    /// check after an upload usually succeeds, because the retry uploads the missing original.
    static func waitingReplacementDelay(afterWaits waits: Int, first: TimeInterval) -> TimeInterval {
        let limit = max(first, 6 * 60 * 60)
        var delay = first
        for _ in 0..<max(0, waits) {
            guard delay < limit else { break }
            delay *= 2
        }
        return min(delay, limit)
    }

    /// The longest wait of a runnable retry other than a full Proton account: the retry policy's cap, its
    /// 30-second minimum after low disk space, and the recheck of a photo the camera still processes.
    private var longestRegularRetryWait: TimeInterval {
        max(configuration.retry.maxDelay, 30, configuration.oneShotSourceRecheckInterval)
    }

    /// The wait until the next persisted retry becomes eligible, or nil when none is pending.
    private func shortestPendingWait() -> TimeInterval? {
        let currentTime = now()
        if let persisted = queue.nextRunnableDate() {
            return max(0.05, persisted.timeIntervalSince(currentTime))
        }
        return nil
    }

    /// One due-based re-check for parked draft rows: a row blocked N times re-enters the queue once
    /// its persisted typed retry date has passed. A draft
    /// that never clears is re-checked at most once per cap window: visible, never hot-looping.
    private func requeueDueBlockedRows() async {
        let currentTime = now()
        let blocked = queue.entries(in: .blockedByDraft, updatedBefore: currentTime, limit: configuration.batchSize)
        var requeued = false
        for entry in blocked {
            let issue = BackupIssueRecord.decode(entry.lastError)
            guard let due = issue?.nextAttemptAt else { continue }
            guard due <= currentTime else { continue }
            guard
                queue.updateState(
                    source: entry.source, revision: entry.revision,
                    state: .discovered, attempts: entry.attempts, lastError: entry.lastError, updatedAt: currentTime
                )
            else {
                stopRequested = true
                return
            }
            adjustProgress(from: .blockedByDraft, to: .discovered)
            requeued = true
        }
        if requeued {
            // A cached "this name is occupied by a draft" view would make the re-check a no-op
            // (and a cached "free" view could double-upload) - re-checks must see server truth.
            await identityResolver.invalidateCachedRemoteState()
        }
    }

    // MARK: - Dedup batch prewarm

    /// How many runnable rows to prewarm per batch, and how many rows to claim before re-warming.
    /// `claimsPerPrime` is kept below `primeBatch` so the next batch is warmed before the current
    /// one is exhausted.
    private static let primeBatch = 400
    private static let claimsPerPrime = 300
    private static let primePlaceholderURL = URL(fileURLWithPath: "/dev/null")

    /// Batch-prewarm the dedup pipeline's remote duplicate cache for the rows about to be processed,
    /// so their per-item `resolve` is a cache hit instead of an individual server round-trip; the
    /// dominant cost when reconciling a large already-backed-up library. Name-hash + source only (no
    /// byte export), so it is cheap; worst case it warms nothing and the per-item path is unchanged.
    private func primeRunnableLookahead() async {
        let cutoff = now()
        var peek = queue.entries(in: .discovered, updatedBefore: cutoff, limit: Self.primeBatch)
        if peek.count < Self.primeBatch {
            peek += queue.entries(in: .queuedForUpload, updatedBefore: cutoff, limit: Self.primeBatch - peek.count)
        }
        guard !peek.isEmpty else { return }
        let descriptors = peek.map { entry in
            UploadResourceDescriptor(
                source: entry.source,
                fileURL: Self.primePlaceholderURL,
                filename: entry.originalFilename,
                fileSize: entry.byteCount ?? 0,
                modificationDate: entry.updatedAt,
                mainResource: nil
            )
        }
        await identityResolver.prime(descriptors)
    }

    // MARK: - Per-entry processing

    private func process(_ entry: UploadBackupSyncQueueEntry, workIntent: LibraryWorkIntent) async {
        let key = Self.key(entry)
        let executionGeneration = UUID()
        activeExecutions[key] = ActiveExecution(
            generation: executionGeneration,
            source: entry.source,
            revision: entry.revision,
            preparationFraction: 0,
            uploadFraction: 0
        )
        let preparationProgress = preparationHandler(for: key, generation: executionGeneration)
        // `claimRunnable` already moved this row to `.checking` in the same transaction that
        // reserved it. Mirror that persisted transition without paying a second SQLite write.
        let persistedState: UploadBackupSyncQueueState = .checking
        inFlightNames[key] = entry.originalFilename
        progress.currentItemName = entry.originalFilename
        // Released the instant this entry settles, so temp exports never accumulate across a pass.
        var resourceCleanup: (@Sendable () -> Void)?
        defer {
            resourceCleanup?()
            endActiveExecution(key: key, generation: executionGeneration)
            inFlightNames[key] = nil
            if progress.currentItemName == entry.originalFilename {
                progress.currentItemName = inFlightNames.values.first
            }
            emitProgress()
        }

        adjustProgress(from: entry.state, to: .checking)
        emitProgress()

        let resolved: BackupResolvedResource?
        do {
            let resolver = self.resolver
            resolved = try await resourceCoordinator.withHeavyPermit(
                LibraryWorkRequest(
                    workload: .backupMaterialization,
                    intent: workIntent,
                    memoryClass: .large
                )
            ) { _ in
                try await resolver.resolve(entry, onPreparationProgress: preparationProgress)
            }
        } catch is CancellationError {
            revert(entry, from: persistedState)
            return
        } catch {
            if stopRequested {
                revert(entry, from: persistedState)
            } else {
                retryOrPark(entry, from: persistedState, error: error)
            }
            return
        }

        // A resolve can already hold temp files, such as an iCloud original its identity pass staged.
        resourceCleanup = resolved?.cleanup
        if sourceWasRemoved(entry) { return }

        guard let resolved else {
            discardMissingSource(entry, from: persistedState)
            return
        }
        resourcePressureStreak = 0  // A successful export indicates available volume space.
        if stopRequested {
            revert(entry, from: persistedState)
            return
        }

        if let reconciliation = entry.remoteCommitReconciliation {
            await reconcileRemoteCommit(
                reconciliation,
                for: entry,
                from: persistedState,
                resolved: resolved,
                workIntent: workIntent
            )
            return
        }

        let scopedOutcome: PrimaryScopedOutcome
        do {
            scopedOutcome = try await identityResolver.withUploadDecision(
                resolved.descriptor.withWorkIntent(workIntent).withBackupRevision(resolved.candidate.snapshot.revision),
                onRemoteCommit: { [queue, now, events] identity, receipt in
                    // Durable before anything else: the grid can swap the pending tile for this photo even if
                    // the app ends before local settlement, and an exclusion that raced the commit is honored.
                    // A failed write stops settlement like a failed receipt write; the next pass resolves the
                    // committed photo as a duplicate instead of uploading it again.
                    if resolved.descriptor.source == entry.source,
                        events?.recordHandoff(
                            source: entry.source,
                            revision: entry.revision,
                            remote: PhotoUID(volumeID: receipt.remoteVolumeID, nodeID: receipt.remoteLinkID),
                            kind: .uploaded
                        ) == .failed
                    {
                        throw UploadError.backend("Pending handoff could not be persisted")
                    }
                    let reconciliation = UploadRemoteCommitReconciliation(
                        source: resolved.descriptor.source,
                        identity: identity,
                        receipt: receipt,
                        descriptor: UploadResourceDescriptorSnapshot(resolved.descriptor),
                        queueBinding: UploadRemoteCommitQueueBinding(
                            source: entry.source,
                            revision: entry.revision
                        )
                    )
                    guard
                        queue.markNeedsRemoteReconciliation(
                            source: entry.source,
                            revision: entry.revision,
                            reconciliation: reconciliation,
                            lastError: "Remote upload is awaiting local reconciliation.",
                            updatedAt: now()
                        )
                    else {
                        throw UploadError.backend("Remote commit reconciliation could not be persisted")
                    }
                },
                operation: { [weak self] preflightResult in
                    guard let self else { throw CancellationError() }
                    if await self.stopWasRequested() { throw CancellationError() }
                    switch preflightResult.decision {
                    case .upload, .uploadReplacingDraft:
                        guard await self.admitsTransfer(for: entry.source) else { throw CancellationError() }
                        await self.recordUploadEvidence(entry)
                        return try await self.performPrimaryUpload(
                            entry,
                            from: persistedState,
                            resolved: resolved,
                            preflight: preflightResult,
                            workIntent: workIntent,
                            preparationProgress: preparationProgress
                        )
                    case .uploadMissingSecondaries, .skip, .awaitDeletionCheck:
                        return .noUpload(.decision(preflightResult))
                    }
                }
            )
        } catch is CancellationError {
            let current = queue.entry(for: entry.source, revision: entry.revision)?.state ?? persistedState
            revert(entry, from: current)
            return
        } catch let settlement as UploadRemoteCommitSettlementError {
            if settlement.reconciliationPersisted {
                adjustProgress(from: .uploading, to: .needsRemoteReconciliation)
                emitProgress()
            } else {
                stopRequested = true
            }
            return
        } catch {
            let current = queue.entry(for: entry.source, revision: entry.revision)?.state ?? persistedState
            if stopRequested { revert(entry, from: current) } else { retryOrPark(entry, from: current, error: error) }
            return
        }

        switch scopedOutcome {
        case .uploaded(let uid):
            adjustProgress(from: .uploading, to: .needsRemoteReconciliation)
            emitProgress()
            await settleCompound(
                entry,
                from: .needsRemoteReconciliation,
                resolved: resolved,
                primaryUID: uid,
                terminal: .completed,
                workIntent: workIntent
            )

        case .decision(let preflightResult):
            switch preflightResult.decision {
            case .awaitDeletionCheck:
                await awaitDeletionCheck(entry, from: persistedState)
            case .uploadMissingSecondaries(let primaryLinkID, _):
                // This entry IS the primary and the policy proved it active remotely; only paired
                // secondaries would need bytes.
                guard recordDeduplicatedHandoff(entry, remoteLinkID: primaryLinkID, from: persistedState) else {
                    return
                }
                await settleCompound(
                    entry, from: persistedState, resolved: resolved,
                    primaryUID: PhotoUID(volumeID: "", nodeID: primaryLinkID),
                    terminal: .alreadyBackedUp,
                    workIntent: workIntent
                )

            case .skip(let reason, let remoteLinkID):
                switch reason {
                case .activeDuplicate, .knownFromManifest:
                    // The primary is proven remote. Secondaries (a Live Photo's paired video) may
                    // still be missing - settle them before any "backed up" claim. The link-only
                    // reference resolves to the photos volume at the transport layer.
                    if let remoteLinkID,
                        !recordDeduplicatedHandoff(entry, remoteLinkID: remoteLinkID, from: persistedState)
                    {
                        return
                    }
                    await settleCompound(
                        entry, from: persistedState, resolved: resolved,
                        primaryUID: remoteLinkID.map { PhotoUID(volumeID: "", nodeID: $0) },
                        terminal: .alreadyBackedUp,
                        workIntent: workIntent
                    )

                case .trashedDuplicate, .deletedRemotely:
                    // Respect the user's remote deletion: no upload, and explicitly not backed up.
                    // No preflight record either - the next scan re-checks, so restoring from the
                    // Proton trash naturally flips this to alreadyBackedUp later.
                    finish(
                        entry, from: persistedState, as: .skippedRemoteDeletion,
                        message: L10n.string("backup.state_skipped_remote_deletion"), resolved: resolved)

                case .draftExists:
                    // Another upload (possibly our own crashed one) occupies the name. Park with
                    // backoff; never a success state. A foreign/ownerless draft that outlives the
                    // ordinary retry budget becomes an honest, dismissible permanent failure instead
                    // of rechecking forever.
                    let attempts = entry.attempts + 1
                    if configuration.retry.shouldPark(attempts: attempts) {
                        guard
                            queue.updateState(
                                source: entry.source,
                                revision: entry.revision,
                                state: .failedPermanent,
                                attempts: attempts,
                                lastError: BackupIssueRecord(
                                    kind: .remoteDraftStale,
                                    detail: L10n.string("backup.issue_remote_draft_stale")
                                ).persistedValue,
                                updatedAt: now()
                            )
                        else {
                            stopRequested = true
                            return
                        }
                        endActiveExecution(key: key, publish: false)
                        adjustProgress(from: persistedState, to: .failedPermanent)
                        emitProgress()
                        return
                    }
                    let nextAttemptAt = now().addingTimeInterval(
                        max(60, configuration.retry.delay(afterAttempts: attempts))
                    )
                    guard
                        queue.updateState(
                            source: entry.source, revision: entry.revision,
                            state: .blockedByDraft, attempts: attempts,
                            lastError: BackupIssueRecord(
                                kind: .remoteDraft,
                                detail: L10n.string("upload.error_remote_draft"),
                                nextAttemptAt: nextAttemptAt
                            ).persistedValue,
                            updatedAt: nextAttemptAt
                        )
                    else {
                        stopRequested = true
                        return
                    }
                    endActiveExecution(key: key, publish: false)
                    adjustProgress(from: persistedState, to: .blockedByDraft)
                    emitProgress()

                case .inconsistentRemoteState:
                    retryOrPark(
                        entry, from: persistedState,
                        error: UploadError.backend(L10n.string("upload.error_remote_inconsistent")))
                }
            case .upload, .uploadReplacingDraft:
                retryOrPark(
                    entry,
                    from: persistedState,
                    error: UploadError.backend("Scoped upload decision returned without transport")
                )
            }
        }
    }

    private func stopWasRequested() -> Bool { stopRequested }

    /// Checked right before every resource transfer, primary and secondary. A source that the person
    /// excluded is removed like a local deletion. An unknown answer ends the pass without removing anything,
    /// so no photo uploads while its exclusion cannot be read.
    private func admitsTransfer(for source: UploadSourceIdentity) async -> Bool {
        guard !removedSources.contains(Self.sourceKey(kind: source.kind, identifier: source.identifier)) else {
            return false
        }
        guard let events else { return true }
        switch events.isExcluded(source: source) {
        case false?:
            return true
        case true?:
            await removeSources(kind: source.kind, identifiers: [source.identifier])
            return false
        case nil:
            stopRequested = true
            return false
        }
    }

    private func recordUploadEvidence(_ entry: UploadBackupSyncQueueEntry) {
        let replaces =
            entry.source.kind == .photoLibraryAsset && entry.source.resource == .primary
            ? editReplacement?.journal.entry(for: entry.source).allSuperseded ?? [] : []
        events?.recordUploadEvidence(source: entry.source, revision: entry.revision, replaces: replaces)
    }

    /// Link-only duplicate results resolve to the photos volume; the grid fills in its volume ID. A failed
    /// write keeps the row retryable, so the mapping and any deferred action are never stranded.
    private func recordDeduplicatedHandoff(
        _ entry: UploadBackupSyncQueueEntry,
        remoteLinkID: String,
        from state: UploadBackupSyncQueueState
    ) -> Bool {
        guard
            events?.recordHandoff(
                source: entry.source,
                revision: entry.revision,
                remote: PhotoUID(volumeID: "", nodeID: remoteLinkID),
                kind: .deduplicated
            ) == .failed
        else { return true }
        retryOrPark(entry, from: state, error: UploadError.backend("Pending handoff could not be persisted"))
        return false
    }

    private func performPrimaryUpload(
        _ entry: UploadBackupSyncQueueEntry,
        from state: UploadBackupSyncQueueState,
        resolved: BackupResolvedResource,
        preflight preflightResult: UploadPreflightResult,
        workIntent: LibraryWorkIntent,
        preparationProgress: @escaping BackupResourcePreparationHandler
    ) async throws -> UploadDecisionOperationResult<PrimaryScopedOutcome> {
        // Before the original is copied: a file that cannot fit into the account is neither copied nor sent. Replacing
        // a draft is left to Proton, because the draft's own blocks may be what fills the account.
        if preflightResult.decision != .uploadReplacingDraft {
            try await uploader.ensureRemoteCapacity(
                forBytes: resolved.descriptor.fileSize, filename: resolved.descriptor.filename)
        }
        let descriptor: UploadResourceDescriptor
        if resolved.hasDeferredMaterialization {
            descriptor = try await resourceCoordinator.withHeavyPermit(
                LibraryWorkRequest(
                    workload: .backupMaterialization,
                    intent: workIntent,
                    memoryClass: .large
                )
            ) { _ in
                try await resolved.materializedDescriptor(onPreparationProgress: preparationProgress)
            }
        } else {
            descriptor = resolved.descriptor
        }
        if resolved.hasDeferredMaterialization,
            descriptor.precomputedSHA1Digest != preflightResult.identity.sha1Digest
        {
            throw CancellationError()
        }
        // Materialization can take a while; an exclusion saved meanwhile must still stop the transfer.
        guard await admitsTransfer(for: entry.source) else { throw CancellationError() }
        let key = Self.key(entry)
        guard transition(entry, from: state, to: .uploading) != nil else {
            throw UploadError.backend("Backup queue could not enter uploading state")
        }
        let token = UUID()
        inFlightTokens[key] = token
        defer {
            inFlightTokens[key] = nil
        }
        // An upload that keeps its earlier uploads names none of them as replaced. An edit that waits for its
        // original still names them, because a reader counts only a named link outside the library as replaced.
        let replacesEarlierUploads =
            editReplacement?.replacesEarlierUploads(of: entry.source, edited: Self.isEdited(resolved)) == true
        let lineage = replacesEarlierUploads ? preflightResult.lineage : nil

        let request = PhotoUploadRequest(
            queueItemID: UUID(),
            cancellationToken: token,
            fileURL: descriptor.fileURL,
            name: descriptor.filename,
            mediaType: resolved.mediaType,
            fileSize: descriptor.fileSize,
            captureTime: resolved.captureDate,
            modificationDate: resolved.descriptor.modificationDate,
            tags: Self.primaryTags(for: resolved.secondaries, sourceTags: resolved.tags),
            additionalMetadata: UploadCameraMetadata.completing(
                resolved.additionalMetadata, fileURL: descriptor.fileURL)
                + (lineage.map { [$0.additionalMetadata] } ?? [])
        )
        .applying(identity: preflightResult.identity)
        .replacingExistingDraft(preflightResult.decision == .uploadReplacingDraft)

        let uid = try await uploadWithWatchdog(
            request,
            progressKey: key,
            itemBaseFraction: 0,
            itemFractionWeight: 1 / Double(1 + resolved.secondaries.count)
        )
        return .remoteCommitted(
            .uploaded(uid),
            receipt: UploadRemoteCommitReceipt(
                remoteVolumeID: uid.volumeID,
                remoteLinkID: uid.nodeID
            )
        )
    }

    private func reconcileRemoteCommit(
        _ reconciliation: UploadRemoteCommitReconciliation,
        for entry: UploadBackupSyncQueueEntry,
        from state: UploadBackupSyncQueueState,
        resolved: BackupResolvedResource,
        workIntent: LibraryWorkIntent
    ) async {
        if reconciliation.source == entry.source,
            events?.recordHandoff(
                source: entry.source,
                revision: entry.revision,
                remote: PhotoUID(
                    volumeID: reconciliation.receipt.remoteVolumeID,
                    nodeID: reconciliation.receipt.remoteLinkID
                ),
                kind: .uploaded
            ) == .failed
        {
            // Keep the receipt: the handoff must be durable before the row can settle.
            parkRemoteReconciliation(
                entry,
                reconciliation: reconciliation,
                from: state,
                message: "Pending handoff could not be persisted."
            )
            return
        }
        let descriptor: UploadResourceDescriptor?
        if resolved.descriptor.source == reconciliation.source {
            descriptor = resolved.descriptor
        } else {
            descriptor =
                resolved.secondaries.first {
                    $0.descriptor.source == reconciliation.source
                }?.descriptor
        }
        guard let descriptor else {
            parkRemoteReconciliation(
                entry,
                reconciliation: reconciliation,
                from: state,
                message: "Committed resource is not currently available for local reconciliation."
            )
            return
        }

        do {
            try await identityResolver.recordUploaded(
                descriptor,
                identity: reconciliation.identity,
                remoteVolumeID: reconciliation.receipt.remoteVolumeID,
                remoteLinkID: reconciliation.receipt.remoteLinkID
            )
        } catch {
            parkRemoteReconciliation(
                entry,
                reconciliation: reconciliation,
                from: state,
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
            return
        }

        if reconciliation.source == resolved.descriptor.source {
            await settleCompound(
                entry,
                from: state,
                resolved: resolved,
                primaryUID: PhotoUID(
                    volumeID: reconciliation.receipt.remoteVolumeID,
                    nodeID: reconciliation.receipt.remoteLinkID
                ),
                terminal: .completed,
                workIntent: workIntent
            )
        } else {
            // The secondary manifest is repaired. Re-run the primary's cheap duplicate decision
            // to recover its UID, then the compound pass will skip this secondary from manifest.
            guard
                queue.updateState(
                    source: entry.source,
                    revision: entry.revision,
                    state: .discovered,
                    attempts: nil,
                    lastError: nil,
                    updatedAt: now()
                )
            else {
                stopRequested = true
                return
            }
            adjustProgress(from: state, to: .discovered)
            emitProgress()
        }
    }

    private func parkRemoteReconciliation(
        _ entry: UploadBackupSyncQueueEntry,
        reconciliation: UploadRemoteCommitReconciliation,
        from state: UploadBackupSyncQueueState,
        message: String
    ) {
        let nextAttempt = now().addingTimeInterval(
            max(1, configuration.retry.delay(afterAttempts: entry.attempts + 1))
        )
        guard
            queue.markNeedsRemoteReconciliation(
                source: entry.source,
                revision: entry.revision,
                reconciliation: reconciliation,
                lastError: message,
                updatedAt: nextAttempt
            )
        else {
            stopRequested = true
            return
        }
        adjustProgress(from: state, to: .needsRemoteReconciliation)
        emitProgress()
    }

    // MARK: - Compound settlement (secondaries after the primary)

    private enum SecondaryOutcome {
        case allSettled
        case failed(remaining: Int, error: any Error)
        case reconciliationPending
        case blockedByDraft
        case skippedRemoteDeletion
        case cancelled
        case sourceChanged
    }

    /// A series uploads its frames as related photos of its main photo.
    private static func isSeries(_ resolved: BackupResolvedResource) -> Bool {
        resolved.secondaries.contains(where: { $0.descriptor.source.resource.isBurstMember })
    }

    private static func isEdited(_ resolved: BackupResolvedResource) -> Bool {
        resolved.candidate.snapshot.editRevision == .unavailable
    }

    private static func holdsOriginal(_ resolved: BackupResolvedResource) -> Bool {
        EditedPhotoReplacement.holdsOriginal(
            editRevision: resolved.candidate.snapshot.editRevision,
            secondaries: resolved.secondaries.map(\.descriptor.source.resource))
    }

    /// Uploads/dedupes any secondary resources, then - and only then - marks the compound backed
    /// up. Partial secondary failure records honest pending state and retries the whole entry;
    /// the primary is never re-uploaded (its manifest row short-circuits the next pass).
    private func settleCompound(
        _ entry: UploadBackupSyncQueueEntry,
        from state: UploadBackupSyncQueueState,
        resolved: BackupResolvedResource,
        primaryUID: PhotoUID?,
        terminal: UploadBackupSyncQueueState,
        workIntent: LibraryWorkIntent
    ) async {
        var persistedState = state
        let isSeries = Self.isSeries(resolved)
        // An edit that replaces an earlier upload uploads its secondaries under the edited photo again: their
        // earlier copies are related photos of the earlier photo and move to the trash with it.
        let replacesEarlierUpload = editReplacement?.isReplacing(entry.source) == true
        if !resolved.secondaries.isEmpty {
            if persistedState != .uploading {
                guard let nextState = transition(entry, from: persistedState, to: .uploading) else { return }
                persistedState = nextState
            }
            guard let primaryUID else {
                // No remote reference for the primary - cannot pair secondaries safely.
                retryOrPark(
                    entry, from: persistedState,
                    error: UploadError.backend(L10n.string("upload.error_remote_inconsistent")))
                return
            }
            switch await settleSecondaries(
                resolved.secondaries,
                primaryUID: primaryUID,
                requiresRelatedMatch: replacesEarlierUpload,
                entry: entry,
                entryKey: Self.key(entry),
                workIntent: workIntent
            ) {
            case .allSettled:
                break
            case .failed(let remaining, let error):
                do {
                    try await preflight.markPending(
                        resolved.candidate.snapshot,
                        pendingResourceCount: remaining
                    )
                } catch {
                    retryOrPark(entry, from: persistedState, error: error)
                    return
                }
                // Preserve the concrete error. In particular, an NSURLError timeout/reset from a
                // secondary must reach `retryOrPark` as a transient network failure and can never
                // consume the compound's permanent retry budget.
                retryOrPark(entry, from: persistedState, error: error)
                return
            case .reconciliationPending:
                adjustProgress(from: persistedState, to: .needsRemoteReconciliation)
                emitProgress()
                return
            case .blockedByDraft:
                do {
                    if try await primaryWasDeletedAfterUpload(resolved.descriptor) {
                        finish(
                            entry,
                            from: persistedState,
                            as: .skippedRemoteDeletion,
                            message: L10n.string("backup.state_skipped_remote_deletion"),
                            resolved: resolved
                        )
                        return
                    }
                } catch {
                    retryOrPark(entry, from: persistedState, error: error)
                    return
                }
                let attempts = entry.attempts + 1
                if configuration.retry.shouldPark(attempts: attempts) {
                    guard
                        queue.updateState(
                            source: entry.source,
                            revision: entry.revision,
                            state: .failedPermanent,
                            attempts: attempts,
                            lastError: BackupIssueRecord(
                                kind: .remoteDraftStale,
                                detail: L10n.string("backup.issue_remote_draft_stale")
                            ).persistedValue,
                            updatedAt: now()
                        )
                    else {
                        stopRequested = true
                        return
                    }
                    adjustProgress(from: persistedState, to: .failedPermanent)
                    emitProgress()
                    return
                }
                let nextAttemptAt = now().addingTimeInterval(
                    max(60, configuration.retry.delay(afterAttempts: attempts))
                )
                guard
                    queue.updateState(
                        source: entry.source,
                        revision: entry.revision,
                        state: .blockedByDraft,
                        attempts: attempts,
                        lastError: BackupIssueRecord(
                            kind: .remoteDraft,
                            detail: L10n.string("upload.error_remote_draft"),
                            nextAttemptAt: nextAttemptAt
                        ).persistedValue,
                        updatedAt: nextAttemptAt
                    )
                else {
                    stopRequested = true
                    return
                }
                endActiveExecution(key: Self.key(entry), publish: false)
                adjustProgress(from: persistedState, to: .blockedByDraft)
                emitProgress()
                return
            case .skippedRemoteDeletion:
                finish(
                    entry,
                    from: persistedState,
                    as: .skippedRemoteDeletion,
                    message: L10n.string("backup.state_skipped_remote_deletion"),
                    resolved: resolved
                )
                return
            case .cancelled:
                revert(entry, from: persistedState)
                return
            case .sourceChanged:
                revert(entry, from: persistedState)
                return
            }
            // Series migration: an earlier build uploaded this main photo alone and untagged. Its members are
            // related to it now, so the existing node needs the bursts tag. The main photo never uploads again.
            if terminal == .alreadyBackedUp, let tagAdder, isSeries {
                do {
                    try await tagAdder.addTags([PhotoTag.bursts.rawValue], to: primaryUID)
                } catch {
                    retryOrPark(entry, from: persistedState, error: error)
                    return
                }
            }
        }
        if let editReplacement, let primaryUID {
            do {
                // Before the trash: forgetting too early costs one extra duplicate check, forgetting too late lets a
                // crash leave an undone edit counted as backed up.
                if replacesEarlierUpload {
                    try await preflight.forgetEarlierStates(of: resolved.candidate.snapshot)
                    guard queue.removeSettledRevisions(of: entry.source, except: entry.revision) else {
                        throw UploadError.backend("Backup queue could not be updated")
                    }
                }
                let outcome = try await editReplacement.replaceSuperseded(
                    of: entry.source,
                    with: primaryUID,
                    edited: Self.isEdited(resolved),
                    holdsOriginal: Self.holdsOriginal(resolved),
                    externalIdentifier: resolved.descriptor.externalIdentifier,
                    localEditTime: resolved.photoLibraryEditTime,
                    localCreationDate: resolved.descriptor.photoLibraryCreationDate,
                    externalIdentifierIsUnique: resolved.descriptor.externalIdentifierIsUnique,
                    originalSHA1Hex: resolved.descriptor.originalSHA1Hex
                )
                SupportEventTrail.shared.record(
                    Self.supportEventKind(of: outcome), subject: entry.source.identifier)
                switch outcome {
                case .replaced(let retiredAny):
                    if retiredAny { await identityResolver.invalidateCachedRemoteState() }
                case .waiting:
                    // Some earlier mains may have retired while another still protects an original resource.
                    await identityResolver.invalidateCachedRemoteState()
                    try await preflight.markPending(resolved.candidate.snapshot)
                    // The key, not a sentence: a new language or new copy keeps the same count.
                    let detail = "backup.issue_waiting_original"
                    let earlier = BackupIssueRecord.decode(entry.lastError)
                    let waits =
                        BackupFailedItem.isWaitingForOriginal(earlier?.detail)
                        ? (earlier?.automaticRetryAttempt ?? 0) + 1 : 0
                    let eligibleAt = now().addingTimeInterval(
                        Self.waitingReplacementDelay(afterWaits: waits, first: min(180, longestRegularRetryWait)))
                    deferSource(
                        entry, from: persistedState, until: eligibleAt,
                        issue: BackupIssueRecord(
                            kind: .unknown, detail: detail, nextAttemptAt: eligibleAt,
                            automaticRetryAttempt: waits
                        ))
                    return
                case .replacementGone:
                    // The person removed the photo that the earlier ones waited for. Like every deletion in
                    // Proton, it stays out of the backup until a restore.
                    finish(
                        entry, from: persistedState, as: .skippedRemoteDeletion,
                        message: L10n.string("backup.state_skipped_remote_deletion"), resolved: resolved)
                    return
                case .kept:
                    break
                }
                events?.settleUploadEvidence(
                    source: entry.source, revision: entry.revision,
                    retired: Set(editReplacement.journal.entry(for: entry.source).retired)
                )
            } catch is CancellationError {
                revert(entry, from: persistedState)
                return
            } catch {
                if stopRequested {
                    revert(entry, from: persistedState)
                } else {
                    retryOrPark(entry, from: persistedState, error: error)
                }
                return
            }
        }
        do {
            try await preflight.markBackedUp(resolved.candidate.snapshot)
        } catch {
            retryOrPark(entry, from: persistedState, error: error)
            return
        }
        finish(entry, from: persistedState, as: terminal, message: nil, resolved: resolved)
    }

    private func awaitDeletionCheck(
        _ entry: UploadBackupSyncQueueEntry, from oldState: UploadBackupSyncQueueState
    ) async {
        guard let journal = editReplacement?.journal else {
            retryOrPark(entry, from: oldState, error: UploadError.backend("Deletion journal is unavailable"))
            return
        }
        do {
            let started = journal.entry(for: entry.source).deletionCheckStartedAt
            let elapsed = started.map { max(0, now().timeIntervalSince($0)) } ?? 0
            // A persisted timestamp proves a prior completed check, even when manual retry cleared last_error.
            if started != nil, elapsed >= 600 {
                if sourceWasRemoved(entry) {
                    endActiveExecution(key: Self.key(entry), publish: false)
                    return
                }
                guard
                    queue.updateState(
                        source: entry.source, revision: entry.revision, state: .failedPermanent,
                        attempts: entry.attempts,
                        lastError: BackupIssueRecord(
                            kind: .deletedElsewhere, detail: L10n.string("backup.issue_deleted_elsewhere")
                        ).persistedValue, updatedAt: now())
                else {
                    stopRequested = true
                    return
                }
                endActiveExecution(key: Self.key(entry), publish: false)
                adjustProgress(from: oldState, to: .failedPermanent)
                emitProgress()
                return
            }
            try journal.startDeletionCheck(at: now(), for: entry.source)
            if !deletionStateInvalidated {
                deletionStateInvalidated = true
                await identityResolver.invalidateCachedRemoteState()
            }
            let delay = started == nil ? 120 : max(60, 600 - elapsed)
            let eligibleAt = now().addingTimeInterval(delay)
            deferSource(
                entry, from: oldState, until: eligibleAt,
                issue: BackupIssueRecord(
                    kind: .unknown, detail: L10n.string("backup.issue_deletion_check"), nextAttemptAt: eligibleAt))
        } catch {
            retryOrPark(entry, from: oldState, error: error)
        }
    }

    private func primaryWasDeletedAfterUpload(_ descriptor: UploadResourceDescriptor) async throws -> Bool {
        guard let decision = try await identityResolver.revalidateKnownRemote(descriptor) else { return false }
        switch decision {
        case .skip(.trashedDuplicate, _), .skip(.deletedRemotely, _):
            return true
        case .upload, .uploadReplacingDraft, .uploadMissingSecondaries, .awaitDeletionCheck,
            .skip(.activeDuplicate, _), .skip(.knownFromManifest, _),
            .skip(.draftExists, _), .skip(.inconsistentRemoteState, _):
            return false
        }
    }

    /// Each secondary goes through the same pipeline (manifest fast path skips ones already
    /// uploaded by a previous attempt) and uploads with `mainPhotoUID` referencing the primary.
    private func settleSecondaries(
        _ secondaries: [BackupSecondaryResource],
        primaryUID: PhotoUID,
        requiresRelatedMatch: Bool,
        entry: UploadBackupSyncQueueEntry,
        entryKey: String,
        workIntent: LibraryWorkIntent
    ) async -> SecondaryOutcome {
        var remaining = secondaries.count
        var completedSecondaries = 0
        var lastError: (any Error)?
        let totalResourceCount = 1 + secondaries.count
        for secondary in secondaries {
            if stopRequested { return .cancelled }
            do {
                let outcome: SecondaryScopedOutcome = try await identityResolver.withUploadDecision(
                    secondary.descriptor.withWorkIntent(workIntent).relatedTo(
                        mainRemoteLinkID: primaryUID.nodeID, requiresRelatedMatch: requiresRelatedMatch),
                    onRemoteCommit: { [queue, now] identity, receipt in
                        let reconciliation = UploadRemoteCommitReconciliation(
                            source: secondary.descriptor.source,
                            identity: identity,
                            receipt: receipt,
                            descriptor: UploadResourceDescriptorSnapshot(secondary.descriptor),
                            queueBinding: UploadRemoteCommitQueueBinding(
                                source: entry.source,
                                revision: entry.revision
                            )
                        )
                        guard
                            queue.markNeedsRemoteReconciliation(
                                source: entry.source,
                                revision: entry.revision,
                                reconciliation: reconciliation,
                                lastError: "Remote secondary is awaiting local reconciliation.",
                                updatedAt: now()
                            )
                        else {
                            throw UploadError.backend("Secondary reconciliation could not be persisted")
                        }
                    },
                    operation: { [weak self] result in
                        guard let self else { throw CancellationError() }
                        if await self.stopWasRequested() { throw CancellationError() }
                        switch result.decision {
                        case .skip(.activeDuplicate, _), .skip(.knownFromManifest, _):
                            return .noUpload(.settled)
                        case .skip(.trashedDuplicate, _), .skip(.deletedRemotely, _):
                            // The user deleted this one photo of the series. The deletion removes that member
                            // only; the main photo and the other members still form the series.
                            return .noUpload(
                                secondary.descriptor.source.resource.isBurstMember ? .settled : .skippedRemoteDeletion)
                        case .skip(.draftExists, _):
                            return .noUpload(.blockedByDraft)
                        case .skip(.inconsistentRemoteState, _), .uploadMissingSecondaries, .awaitDeletionCheck:
                            return .noUpload(.inconsistent)
                        case .upload, .uploadReplacingDraft:
                            if result.decision != .uploadReplacingDraft {
                                try await self.uploader.ensureRemoteCapacity(
                                    forBytes: secondary.descriptor.fileSize, filename: secondary.descriptor.filename)
                            }
                            let uploadDescriptor: UploadResourceDescriptor
                            if secondary.hasDeferredMaterialization {
                                uploadDescriptor = try await self.resourceCoordinator.withHeavyPermit(
                                    LibraryWorkRequest(
                                        workload: .backupMaterialization,
                                        intent: workIntent,
                                        memoryClass: .large
                                    )
                                ) { _ in
                                    try await secondary.materializedDescriptor(
                                        onPreparationProgress: preparationHandler(for: entryKey)
                                    )
                                }
                            } else {
                                uploadDescriptor = secondary.descriptor
                            }
                            if secondary.hasDeferredMaterialization,
                                uploadDescriptor.precomputedSHA1Digest != result.identity.sha1Digest
                            {
                                throw SecondarySourceChangedError()
                            }
                            let uid = try await self.performSecondaryUpload(
                                secondary,
                                descriptor: uploadDescriptor,
                                identity: result.identity,
                                replacingDraft: result.decision == .uploadReplacingDraft,
                                primaryUID: primaryUID,
                                entryKey: entryKey,
                                completedSecondaries: completedSecondaries,
                                totalResourceCount: totalResourceCount
                            )
                            return .remoteCommitted(
                                .settled,
                                receipt: UploadRemoteCommitReceipt(
                                    remoteVolumeID: uid.volumeID,
                                    remoteLinkID: uid.nodeID
                                )
                            )
                        }
                    }
                )
                switch outcome {
                case .settled:
                    if queue.entry(for: entry.source, revision: entry.revision)?.state == .needsRemoteReconciliation {
                        guard
                            queue.updateState(
                                source: entry.source,
                                revision: entry.revision,
                                state: .uploading,
                                attempts: nil,
                                lastError: nil,
                                updatedAt: now()
                            )
                        else {
                            stopRequested = true
                            return .cancelled
                        }
                    }
                    remaining -= 1
                    completedSecondaries += 1
                case .blockedByDraft:
                    return .blockedByDraft
                case .skippedRemoteDeletion:
                    return .skippedRemoteDeletion
                case .inconsistent:
                    return .failed(
                        remaining: remaining,
                        error: UploadError.backend(L10n.string("upload.error_remote_inconsistent"))
                    )
                }
            } catch is SecondarySourceChangedError {
                return .sourceChanged
            } catch let settlement as UploadRemoteCommitSettlementError {
                if settlement.reconciliationPersisted {
                    return .reconciliationPending
                }
                stopRequested = true
                return .cancelled
            } catch is CancellationError {
                return .cancelled
            } catch {
                if stopRequested { return .cancelled }
                lastError = error
            }
        }
        return remaining == 0
            ? .allSettled
            : .failed(
                remaining: remaining,
                error: lastError ?? UploadError.backend(L10n.string("upload.error_remote_inconsistent"))
            )
    }

    /// Proton tags of a compound's main photo: the source's own tags, plus tag 3 for a Live Photo and tag 7 for a
    /// series, which the compound needs at creation.
    static func primaryTags(for secondaries: [BackupSecondaryResource], sourceTags: [Int] = []) -> [Int] {
        var tags = Set(sourceTags)
        if secondaries.contains(where: { $0.descriptor.source.resource == .livePairedVideo }) {
            tags.insert(PhotoTag.livePhotos.rawValue)
        }
        if secondaries.contains(where: { $0.descriptor.source.resource.isBurstMember }) {
            tags.insert(PhotoTag.bursts.rawValue)
        }
        return tags.sorted()
    }

    static func secondaryTags(for resource: UploadSourceIdentity.Resource) -> [Int] {
        if resource == .livePairedVideo { return [PhotoTag.livePhotos.rawValue] }
        if resource.isBurstMember { return [PhotoTag.bursts.rawValue] }
        return []
    }

    private enum SecondaryScopedOutcome: Sendable {
        case settled
        case blockedByDraft
        case skippedRemoteDeletion
        case inconsistent
    }

    private struct SecondarySourceChangedError: Error {}

    private func performSecondaryUpload(
        _ secondary: BackupSecondaryResource,
        descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        replacingDraft: Bool,
        primaryUID: PhotoUID,
        entryKey: String,
        completedSecondaries: Int,
        totalResourceCount: Int
    ) async throws -> PhotoUID {
        guard await admitsTransfer(for: descriptor.source) else { throw CancellationError() }
        let token = UUID()
        let tokenKey = "\(entryKey)#\(descriptor.source.resource.rawValue)"
        inFlightTokens[tokenKey] = token
        defer { inFlightTokens[tokenKey] = nil }
        let request = PhotoUploadRequest(
            queueItemID: UUID(),
            cancellationToken: token,
            fileURL: descriptor.fileURL,
            name: descriptor.filename,
            mediaType: secondary.mediaType,
            fileSize: descriptor.fileSize,
            captureTime: secondary.descriptor.modificationDate,
            modificationDate: descriptor.modificationDate,
            tags: Self.secondaryTags(for: descriptor.source.resource),
            additionalMetadata: UploadCameraMetadata.completing(
                secondary.additionalMetadata, fileURL: descriptor.fileURL),
            mainPhotoUID: primaryUID
        )
        .applying(identity: identity)
        .replacingExistingDraft(replacingDraft)
        return try await uploadWithWatchdog(
            request,
            progressKey: entryKey,
            itemBaseFraction: Double(1 + completedSecondaries) / Double(totalResourceCount),
            itemFractionWeight: 1 / Double(totalResourceCount)
        )
    }

    // MARK: - Transitions (persist first, then adjust the in-memory mirror)

    private func transition(
        _ entry: UploadBackupSyncQueueEntry,
        from oldState: UploadBackupSyncQueueState,
        to newState: UploadBackupSyncQueueState
    ) -> UploadBackupSyncQueueState? {
        guard !sourceWasRemoved(entry) else { return nil }
        guard
            queue.updateState(
                source: entry.source, revision: entry.revision,
                state: newState, attempts: nil, lastError: nil, updatedAt: now()
            )
        else {
            stopRequested = true
            return nil
        }
        adjustProgress(from: oldState, to: newState)
        emitProgress()
        return newState
    }

    private func finish(
        _ entry: UploadBackupSyncQueueEntry,
        from oldState: UploadBackupSyncQueueState,
        as terminal: UploadBackupSyncQueueState,
        message: String?,
        resolved: BackupResolvedResource?
    ) {
        guard !sourceWasRemoved(entry) else { return }
        clearRemoteIndexExecutionFraction()
        endActiveExecution(key: Self.key(entry), publish: false)
        let persistedMessage: String? =
            switch terminal {
            case .sourceMissing:
                message.map { BackupIssueRecord(kind: .sourceMissing, detail: $0).persistedValue }
            case .skippedRemoteDeletion:
                message.map { BackupIssueRecord(kind: .remoteDeletion, detail: $0).persistedValue }
            default:
                message
            }
        let backedUp = terminal == .completed || terminal == .alreadyBackedUp
        if backedUp, entry.source.kind == .photoLibraryAsset, entry.source.resource == .primary,
            let journal = editReplacement?.journal
        {
            // The photo is in Proton Drive, so a choice about its deletion no longer applies. A consent that a failed
            // write leaves behind covers only its own revision, which is backed up now: it cannot upload a later one.
            try? journal.clearDeletionChoice(for: entry.source)
        }
        guard
            queue.updateState(
                source: entry.source, revision: entry.revision,
                state: terminal, attempts: nil, lastError: persistedMessage, updatedAt: now()
            )
        else {
            stopRequested = true
            return
        }
        // A settled item means the connection is working again; ease the network backoff one step so
        // concurrency ramps back toward the policy limit (gentle recovery, not an all-at-once jump).
        if terminal.isTerminalSuccess, networkErrorStreak > 0 {
            networkErrorStreak -= 1
        }
        if backedUp {
            // The resolved revision can be newer than the queued one when the photo changed meanwhile; every row up
            // to it that ended without a backup is obsolete, and the drifted row below is written fresh.
            let resolvedRevision =
                resolved.map { max($0.candidate.snapshot.revision, entry.revision) } ?? entry.revision
            queue.removeUnsavedEarlierRevisions(of: entry.source, through: resolvedRevision, except: entry.revision)
        }
        adjustProgress(from: oldState, to: terminal)
        if let resolved { closeDriftedRevisionRow(entry, resolved: resolved, as: terminal) }
        emitProgress()
    }

    /// When the file changed between scan and processing, the current revision was handled, not
    /// the scanned one. Record a row for the resolved revision too, so the next scan's direct
    /// preflight hit lines up with a queue row and totals stay truthful.
    private func closeDriftedRevisionRow(
        _ entry: UploadBackupSyncQueueEntry,
        resolved: BackupResolvedResource,
        as terminal: UploadBackupSyncQueueState
    ) {
        let snapshot = resolved.candidate.snapshot
        guard snapshot.revision != entry.revision else { return }
        guard
            queue.upsert(
                UploadBackupSyncQueueEntry(
                    source: snapshot.source,
                    revision: snapshot.revision,
                    originalFilename: resolved.candidate.originalFilename,
                    byteCount: resolved.candidate.byteCount,
                    state: terminal,
                    attempts: 0,
                    lastError: nil,
                    updatedAt: now()
                ))
        else {
            stopRequested = true
            return
        }
        adjustProgress(from: nil, to: terminal)
    }

    /// Defers a source with unfinished resources without spending its failure budget or claiming backup success.
    private func deferSource(
        _ entry: UploadBackupSyncQueueEntry,
        from oldState: UploadBackupSyncQueueState,
        until eligibleAt: Date,
        issue: BackupIssueRecord? = nil
    ) {
        endActiveExecution(key: Self.key(entry), publish: false)
        if sourceWasRemoved(entry) { return }
        guard
            queue.updateState(
                source: entry.source, revision: entry.revision,
                state: .discovered,
                attempts: entry.attempts,
                lastError: issue?.persistedValue,
                updatedAt: max(eligibleAt, now())
            )
        else {
            stopRequested = true
            return
        }
        adjustProgress(from: oldState, to: .discovered)
        emitProgress()
    }

    private func retryOrPark(
        _ entry: UploadBackupSyncQueueEntry,
        from oldState: UploadBackupSyncQueueState,
        error: Error
    ) {
        endActiveExecution(key: Self.key(entry), publish: false)
        if sourceWasRemoved(entry) { return }
        if case UploadError.fileMissing = error {
            discardMissingSource(entry, from: oldState)
            return
        }
        // Not a failure: the camera still processes the photo. Uploading now would send its preliminary
        // version and then the finished one again. The row waits, without an attempt, until the end of the
        // camera's window: the platform's change notification enqueues the finished photo as a new revision
        // sooner, so no timer re-checks it before that date. Only a one-shot drain that the user waits for checks
        // again sooner. A known state keeps older builds able to read the row.
        if case UploadError.sourceNotReady(_, let until) = error {
            let recheck =
                drainMode == .waitForScheduledRetries
                ? min(until, now().addingTimeInterval(configuration.oneShotSourceRecheckInterval)) : until
            deferSource(
                entry, from: oldState, until: recheck,
                issue: BackupIssueRecord(
                    kind: .unknown, detail: "error.upload_source_not_ready", nextAttemptAt: recheck))
            return
        }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

        // Disk-space pressure is not the item's fault: it must never burn the retry budget into a
        // permanent `.failed` (that is exactly what stranded a whole library behind an unactionable
        // "needs attention"). Requeue it runnable with a short backoff, leave its attempt count
        // untouched, and let the pass-level guard end the drain if the volume stays full.
        if Self.isTransientResourcePressure(error) {
            resourcePressureStreak += 1
            let eligibleAt = now().addingTimeInterval(
                max(30, configuration.retry.delay(afterAttempts: resourcePressureStreak))
            )
            guard
                queue.updateState(
                    source: entry.source, revision: entry.revision,
                    state: .discovered,
                    attempts: entry.attempts,
                    lastError: BackupIssueRecord(
                        kind: .deviceStorage, detail: message, nextAttemptAt: eligibleAt
                    ).persistedValue,
                    updatedAt: eligibleAt
                )
            else {
                stopRequested = true
                return
            }
            adjustProgress(from: oldState, to: .discovered)
            emitProgress()
            return
        }

        // A transport-level network failure (connection reset, timeout, offline) is environmental, not
        // the item's fault: never burn its retry budget into a permanent `.failed`. Requeue runnable
        // with a short backoff, and grow a network-error streak so the drain throttles its concurrency
        // down; many parallel requests are exactly what provokes NSURLErrorNetworkConnectionLost on a
        // marginal link; then ramps back up as calls start succeeding again.
        if Self.isTransientNetwork(error) {
            networkErrorStreak = min(Self.maxNetworkBackoff, networkErrorStreak + 1)
            let issue = automaticRetryIssue(
                kind: .network,
                detail: message,
                previous: BackupIssueRecord.decode(entry.lastError)
            )
            guard
                queue.updateState(
                    source: entry.source, revision: entry.revision,
                    state: .discovered,
                    attempts: entry.attempts,
                    lastError: issue.persistedValue,
                    updatedAt: issue.nextAttemptAt ?? now()
                )
            else {
                stopRequested = true
                return
            }
            adjustProgress(from: oldState, to: .discovered)
            emitProgress()
            return
        }

        // A full Proton account is not the item's fault either. The item waits without burning its attempts; the
        // check is cheap, but reaching it may download the original from iCloud again, so it recurs only rarely.
        // Freeing space or a larger plan and Back Up Now take it up at once.
        if case UploadError.accountStorageFull = error {
            let eligibleAt = now().addingTimeInterval(Self.accountStorageRecheckInterval)
            guard
                queue.updateState(
                    source: entry.source, revision: entry.revision,
                    state: .discovered,
                    attempts: entry.attempts,
                    lastError: BackupIssueRecord(
                        kind: .accountStorage, detail: message, nextAttemptAt: eligibleAt
                    ).persistedValue,
                    updatedAt: eligibleAt
                )
            else {
                stopRequested = true
                return
            }
            adjustProgress(from: oldState, to: .discovered)
            emitProgress()
            return
        }

        // Rate limits and temporary Proton service failures are environmental, just like a lost
        // connection. Keep the item runnable indefinitely with bounded backoff; a healthy photo must
        // never become a permanent failure merely because the service stayed unavailable longer than
        // the ordinary per-item retry budget.
        if case UploadError.retryableBackend = error {
            let issue = automaticRetryIssue(
                kind: .remoteService,
                detail: message,
                previous: BackupIssueRecord.decode(entry.lastError)
            )
            guard
                queue.updateState(
                    source: entry.source, revision: entry.revision,
                    state: .discovered,
                    attempts: entry.attempts,
                    lastError: issue.persistedValue,
                    updatedAt: issue.nextAttemptAt ?? now()
                )
            else {
                stopRequested = true
                return
            }
            adjustProgress(from: oldState, to: .discovered)
            emitProgress()
            return
        }

        let attempts = entry.attempts + 1
        let issue = Self.issueKind(for: error)
        if configuration.retry.shouldPark(attempts: attempts) {
            guard
                queue.updateState(
                    source: entry.source, revision: entry.revision,
                    state: .failed,
                    attempts: attempts,
                    lastError: BackupIssueRecord(kind: issue, detail: message).persistedValue,
                    updatedAt: now()
                )
            else {
                stopRequested = true
                return
            }
            clearRemoteIndexExecutionFraction()
            adjustProgress(from: oldState, to: .failed)
        } else {
            let eligibleAt = now().addingTimeInterval(configuration.retry.delay(afterAttempts: attempts))
            guard
                queue.updateState(
                    source: entry.source, revision: entry.revision,
                    state: .discovered,
                    attempts: attempts,
                    lastError: BackupIssueRecord(
                        kind: issue, detail: message, nextAttemptAt: eligibleAt
                    ).persistedValue,
                    updatedAt: eligibleAt
                )
            else {
                stopRequested = true
                return
            }
            adjustProgress(from: oldState, to: .discovered)
        }
        emitProgress()
    }

    /// Stop/cancel path: put the row back where the next pass picks it up, without burning an
    /// attempt (stopping the app is not a failure of the item).
    private func revert(_ entry: UploadBackupSyncQueueEntry, from oldState: UploadBackupSyncQueueState) {
        endActiveExecution(key: Self.key(entry), publish: false)
        if sourceWasRemoved(entry) { return }
        let runnable: UploadBackupSyncQueueState =
            (oldState == .uploading || oldState == .finalizing)
            ? .queuedForUpload
            : .discovered
        guard
            queue.updateState(
                source: entry.source, revision: entry.revision,
                state: runnable, attempts: nil, lastError: entry.lastError, updatedAt: now()
            )
        else {
            stopRequested = true
            return
        }
        adjustProgress(from: oldState, to: runnable)
        emitProgress()
    }

    private func discardMissingSource(
        _ entry: UploadBackupSyncQueueEntry,
        from oldState: UploadBackupSyncQueueState
    ) {
        endActiveExecution(key: Self.key(entry), publish: false)
        guard queue.remove(source: entry.source, revision: entry.revision) else {
            if queue.entry(for: entry.source, revision: entry.revision) != nil {
                stopRequested = true
            }
            return
        }
        addToProgress(oldState, sign: -1)
        progress.total = max(0, progress.total - 1)
        emitProgress()
    }

    private func sourceWasRemoved(_ entry: UploadBackupSyncQueueEntry) -> Bool {
        removedSources.contains(Self.sourceKey(kind: entry.source.kind, identifier: entry.source.identifier))
    }

    private func refreshProgressFromQueue() {
        let previous = progress
        progress = BackupSyncProgress(
            summary: queue.summary(),
            currentItemName: previous.currentItemName,
            isRunning: previous.isRunning
        )
        progress.isPausedByPolicy = previous.isPausedByPolicy
        progress.remoteIndexPreparation = previous.remoteIndexPreparation
        progress.remoteIndexPreparationFailed = previous.remoteIndexPreparationFailed
        progress.remoteIndexPreparationIssue = previous.remoteIndexPreparationIssue
        progress.activeTransfer = previous.activeTransfer
        progress.activeExecutionItemEquivalents = previous.activeExecutionItemEquivalents
        progress.outstanding = previous.outstanding
    }

    // MARK: - Progress mirror

    /// Mirrors one persisted row move onto the in-memory snapshot. The runner is the queue's
    /// only writer during a pass, so incremental mirroring stays exact; the final snapshot is
    /// re-read from the store regardless. `oldState == nil` means a row was created.
    private func adjustProgress(from oldState: UploadBackupSyncQueueState?, to newState: UploadBackupSyncQueueState) {
        addToProgress(newState, sign: 1)
        if let oldState {
            addToProgress(oldState, sign: -1)
        } else {
            progress.total += 1
        }
    }

    private func addToProgress(_ state: UploadBackupSyncQueueState, sign: Int) {
        switch state {
        case .discovered:
            progress.waiting += sign
        case .queuedForUpload:
            progress.waiting += sign
            progress.uploadQueued += sign
        case .needsRemoteReconciliation:
            progress.waiting += sign
        case .checking, .hashing, .duplicateChecking:
            progress.checking += sign
        case .uploading, .finalizing:
            progress.uploading += sign
        case .alreadyBackedUp:
            progress.alreadyBackedUp += sign
        case .completed:
            progress.uploaded += sign
        case .skippedRemoteDeletion:
            progress.skippedRemoteDeletions += sign
        case .sourceMissing:
            progress.sourceMissing += sign
        case .blockedByDraft:
            progress.blocked += sign
        case .failed:
            progress.failed += sign
        case .failedPermanent:
            progress.failed += sign
        case .dismissedFailure:
            progress.dismissedFailures += sign
        case .paused:
            progress.paused += sign
        }
    }

    private func emitProgress() {
        onProgress?(progress)
    }

    /// Errors that reflect a temporary lack of disk space rather than a bad item. These are
    /// retried indefinitely (with backoff) and never parked as `.failed`.
    private static func isTransientResourcePressure(_ error: Error) -> Bool {
        switch error as? BackupTempFileStore.BackupTempFileError {
        case .diskBudgetExceeded, .needsFreeSpace: true
        case nil: false
        }
    }

    /// How long an item that did not fit into the Proton account waits before the next automatic check.
    static let accountStorageRecheckInterval: TimeInterval = 6 * 3600

    private static func issueKind(for error: Error) -> BackupIssueKind {
        if isTransientResourcePressure(error) { return .deviceStorage }
        if isTransientNetwork(error) { return .network }
        switch error {
        case UploadError.unsupportedFile:
            return .unsupported
        case UploadError.fileMissing:
            return .sourceMissing
        case UploadError.permissionDenied:
            return .permission
        case UploadError.transport:
            return .network
        case UploadError.retryableBackend, UploadError.backend, UploadError.albumStep:
            return .remoteService
        case UploadError.accountStorageFull:
            return .accountStorage
        default:
            return .unknown
        }
    }

    /// Repeated automatic failures keep a durable backoff ordinal. Network and remote-service outages
    /// intentionally share one domain, while the queue row's finite item-failure budget stays intact.
    private func automaticRetryIssue(
        kind: BackupIssueKind,
        detail: String,
        previous: BackupIssueRecord?
    ) -> BackupIssueRecord {
        func isEnvironmental(_ value: BackupIssueKind) -> Bool {
            value == .network || value == .remoteService
        }
        let previousAttempt: Int
        if let previous,
            previous.kind == kind || (isEnvironmental(previous.kind) && isEnvironmental(kind))
        {
            previousAttempt = previous.automaticRetryAttempt
        } else {
            previousAttempt = 0
        }
        let attempt = min(32, previousAttempt + 1)
        return BackupIssueRecord(
            kind: kind,
            detail: detail,
            nextAttemptAt: now().addingTimeInterval(configuration.retry.delay(afterAttempts: attempt)),
            automaticRetryAttempt: attempt
        )
    }

    /// Transport-level failures that are the network's fault, not the item's: a dropped/reset
    /// connection, a timeout, or being briefly offline. These must never park an item as `.failed`
    /// (the photo is fine, the link isn't) and they drive the adaptive concurrency backoff. Matches
    /// both `URLError` and an `NSError` in the URL-error domain (as the Proton SDK may surface it).
    static func isTransientNetwork(_ error: Error) -> Bool {
        let transientCodes: Set<Int> = [
            NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
            NSURLErrorResourceUnavailable, NSURLErrorSecureConnectionFailed, NSURLErrorCannotLoadFromNetwork,
            NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed, NSURLErrorRequestBodyStreamExhausted,
        ]
        if case UploadError.transport(let code, _) = error, transientCodes.contains(code) { return true }
        if let urlError = error as? URLError, transientCodes.contains(urlError.errorCode) { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && transientCodes.contains(ns.code)
    }

    /// Runs one backend transfer with a monotonic inactivity watchdog. This protects the persistent
    /// queue from an SDK continuation that never completes: a stalled transfer is cancelled and
    /// returned as a retryable transport timeout, while a slow transfer can run indefinitely as
    /// long as the backend continues to report progress.
    private func uploadWithWatchdog(
        _ request: PhotoUploadRequest,
        progressKey: String,
        itemBaseFraction: Double,
        itemFractionWeight: Double
    ) async throws -> PhotoUID {
        let activity = BackupUploadActivity()
        let race = BackupUploadRace()
        let uploader = uploader
        let runner = self
        let timeout = configuration.uploadStallTimeout
        let pollInterval = configuration.uploadStallPollInterval
        beginActiveTransfer(
            key: progressKey,
            generation: request.cancellationToken,
            totalBytes: request.fileSize,
            itemBaseFraction: itemBaseFraction,
            itemFractionWeight: itemFractionWeight
        )
        defer { endActiveTransfer(key: progressKey, generation: request.cancellationToken) }

        let uploadTask = Task {
            do {
                // Coalesce byte callbacks before the actor hop; markProgress stays unconditional
                // so the watchdog still treats every raw callback as transfer liveness.
                let progressGate = BackupUploadCallbackGate { progress in
                    Task {
                        await runner.updateActiveTransfer(
                            key: progressKey,
                            generation: request.cancellationToken,
                            progress: progress
                        )
                    }
                }
                let uid = try await uploader.upload(request) { progress in
                    activity.markProgress()
                    progressGate.publish(progress)
                }
                race.resolve(.success(uid))
            } catch {
                race.resolve(.failure(error))
            }
        }
        let join = BackupUploadJoin(
            uploadTask: uploadTask,
            race: race,
            uploader: uploader,
            token: request.cancellationToken
        )
        inFlightJoins[request.cancellationToken] = join
        defer { inFlightJoins[request.cancellationToken] = nil }

        let watchdogTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard activity.secondsSinceProgress >= timeout else { continue }
                if race.resolve(.timedOut) {
                    await join.cancelAndJoin()
                }
                return
            }
        }

        let resolution = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            uploadTask.cancel()
            watchdogTask.cancel()
            race.resolve(.cancelled)
        }
        watchdogTask.cancel()

        switch resolution {
        case .success(let uid):
            await join.settle()
            return uid
        case .failure(let error):
            await join.settle()
            throw error
        case .timedOut:
            await join.cancelAndJoin()
            throw UploadError.transport(
                code: NSURLErrorTimedOut,
                message: URLError(.timedOut).localizedDescription
            )
        case .cancelled:
            await join.cancelAndJoin()
            throw CancellationError()
        }
    }

    private func beginActiveTransfer(
        key: String,
        generation: UUID,
        totalBytes: Int64,
        itemBaseFraction: Double,
        itemFractionWeight: Double
    ) {
        activeTransfers[key] = ActiveTransfer(
            generation: generation,
            totalBytes: max(0, totalBytes),
            byteFraction: 0,
            itemBaseFraction: min(0.999, max(0, itemBaseFraction)),
            itemFractionWeight: max(0, itemFractionWeight)
        )
        updateExecutionUploadFraction(key: key, fraction: itemBaseFraction)
        publishActiveTransferProgress()
    }

    private func updateActiveTransfer(key: String, generation: UUID, progress uploadProgress: UploadProgress) {
        guard uploadProgress.phase == .uploading,
            var transfer = activeTransfers[key],
            transfer.generation == generation
        else { return }
        let clamped = min(1, max(0, uploadProgress.fraction))
        // One-percent quantization bounds actor/UI churn while advancing for each SDK block.
        let quantized = floor(clamped * 100) / 100
        guard quantized > transfer.byteFraction else { return }
        transfer.byteFraction = quantized
        activeTransfers[key] = transfer
        updateExecutionUploadFraction(
            key: key,
            fraction: transfer.itemBaseFraction + transfer.itemFractionWeight * transfer.byteFraction
        )
        publishActiveTransferProgress()
    }

    private func endActiveTransfer(key: String, generation: UUID) {
        guard activeTransfers[key]?.generation == generation else { return }
        activeTransfers.removeValue(forKey: key)
        publishActiveTransferProgress()
    }

    private func publishActiveTransferProgress() {
        guard !activeTransfers.isEmpty else {
            if progress.activeTransfer != nil {
                progress.activeTransfer = nil
            }
            publishActiveExecutionProgress()
            return
        }
        var totalBytes: Int64 = 0
        var completedBytes: Int64 = 0
        var itemEquivalents = 0.0
        for transfer in activeTransfers.values {
            totalBytes += transfer.totalBytes
            completedBytes += Int64((Double(transfer.totalBytes) * transfer.byteFraction).rounded(.down))
            itemEquivalents += min(
                0.999,
                transfer.itemBaseFraction + transfer.itemFractionWeight * transfer.byteFraction
            )
        }
        let candidate = BackupActiveTransferProgress(
            activeItemCount: activeTransfers.count,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            completedItemEquivalents: itemEquivalents
        )
        guard candidate != progress.activeTransfer else { return }
        progress.activeTransfer = candidate
        publishActiveExecutionProgress()
    }

    private func preparationHandler(for key: String) -> BackupResourcePreparationHandler {
        guard let generation = activeExecutions[key]?.generation else { return { _ in } }
        return preparationHandler(for: key, generation: generation)
    }

    private func preparationHandler(for key: String, generation: UUID) -> BackupResourcePreparationHandler {
        let gate = BackupPreparationCallbackGate { [weak self] fraction in
            Task {
                await self?.updatePreparationProgress(
                    key: key,
                    generation: generation,
                    fraction: fraction
                )
            }
        }
        return { value in gate.publish(value.completedItemEquivalent) }
    }

    private func updatePreparationProgress(key: String, generation: UUID, fraction: Double) {
        guard var execution = activeExecutions[key], execution.generation == generation else { return }
        guard fraction > execution.preparationFraction else { return }
        execution.preparationFraction = fraction
        activeExecutions[key] = execution
        publishActiveExecutionProgress()
    }

    private func updateExecutionUploadFraction(key: String, fraction: Double) {
        guard var execution = activeExecutions[key] else { return }
        let clamped = min(0.999, max(0, fraction))
        guard clamped > execution.uploadFraction else { return }
        execution.uploadFraction = clamped
        activeExecutions[key] = execution
    }

    private func endActiveExecution(key: String, generation: UUID? = nil, publish: Bool = true) {
        if let generation, activeExecutions[key]?.generation != generation { return }
        guard let ended = activeExecutions.removeValue(forKey: key) else { return }
        if ended.reportedStep != nil {
            events?.reportProgress(source: ended.source, revision: ended.revision, step: nil)
        }
        publishActiveExecutionProgress(emit: publish)
    }

    private func clearRemoteIndexExecutionFraction() {
        guard remoteIndexExecutionFraction > 0 else { return }
        remoteIndexExecutionFraction = 0
        publishActiveExecutionProgress(emit: false)
    }

    private func publishActiveExecutionProgress(emit: Bool = true) {
        reportItemProgress()
        let activeFractions = activeExecutions.values.map(Self.fraction)
        var itemEquivalents = activeFractions.reduce(0, +)
        if remoteIndexExecutionFraction > 0 {
            if let handoff = activeFractions.max() {
                itemEquivalents -= handoff
                itemEquivalents +=
                    remoteIndexExecutionFraction
                    + (0.999 - remoteIndexExecutionFraction) * handoff
            } else {
                itemEquivalents = remoteIndexExecutionFraction
            }
        }
        guard itemEquivalents != progress.activeExecutionItemEquivalents else { return }
        progress.activeExecutionItemEquivalents = itemEquivalents
        if emit { emitProgress() }
    }

    private static func fraction(_ execution: ActiveExecution) -> Double {
        let preparation = execution.preparationFraction
        let upload = execution.uploadFraction
        return min(0.999, preparation + (0.999 - preparation) * upload)
    }

    /// Sends each active source's ring step when it changes.
    private func reportItemProgress() {
        guard let events else { return }
        for (key, execution) in activeExecutions {
            let step = BackupProgressStep.step(for: Self.fraction(execution))
            guard step != execution.reportedStep else { continue }
            activeExecutions[key]?.reportedStep = step
            events.reportProgress(source: execution.source, revision: execution.revision, step: step)
        }
    }

    private static func key(_ entry: UploadBackupSyncQueueEntry) -> String {
        "\(entry.source.kind.rawValue)|\(entry.source.identifier)|\(entry.source.resource.rawValue)|\(entry.revision.rawValue)"
    }

    private static func sourceKey(kind: UploadSourceIdentity.Kind, identifier: String) -> String {
        "\(kind.rawValue)|\(identifier)"
    }

    private static func remoteIndexItemEquivalent(
        _ progress: UploadRemoteIndexPreparationProgress
    ) -> Double {
        let fraction: Double
        if let total = progress.total, total > 0 {
            fraction = min(1, max(0, Double(progress.completed) / Double(total)))
        } else {
            fraction = 0
        }
        return switch progress.phase {
        case .loading: 0.01 + 0.07 * fraction
        case .indexing: 0.08 + 0.10 * fraction
        case .applyingChanges: 0.18 + 0.069 * fraction
        case .ready: 0.249
        }
    }
}

/// PhotoKit can call progress handlers for every streamed block. Quantizing before the actor hop keeps
/// preparation liveness bounded to at most 100 callbacks per item while preserving monotonic progress.
private final class BackupPreparationCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBucket = -1
    private let handler: @Sendable (Double) -> Void

    init(handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    func publish(_ fraction: Double) {
        let clamped = min(0.999, max(0, fraction))
        let bucket = Int((clamped * 100).rounded(.down))
        let shouldPublish = lock.withLock {
            guard bucket > lastBucket else { return false }
            lastBucket = bucket
            return true
        }
        if shouldPublish { handler(Double(bucket) / 100) }
    }
}

/// Upload backends can call the byte-progress handler for every streamed block, and each forwarded
/// callback spawns a task that hops onto the runner actor. Bucketing uploading phase progress before
/// that hop bounds the spawned-task count to at most 100 per transfer. Only the actor hop is gated;
/// watchdog liveness (`markProgress`) keeps seeing every raw callback, and the original progress
/// value is forwarded unchanged so terminal progress and phase transitions stay accurate.
final class BackupUploadCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBucket = -1
    private var lastPhase: UploadProgress.Phase?
    private let handler: @Sendable (UploadProgress) -> Void

    init(handler: @escaping @Sendable (UploadProgress) -> Void) {
        self.handler = handler
    }

    func publish(_ progress: UploadProgress) {
        let shouldPublish = lock.withLock {
            if progress.phase != .uploading {
                guard progress.phase != lastPhase else { return false }
                lastPhase = progress.phase
                return true
            }

            // Keep phase transitions and the terminal 1.0 callback visible, while the byte
            // fraction remains a monotonic high-water mark across any phase restart.
            lastPhase = .uploading
            let clamped = min(1, max(0, progress.fraction))
            let bucket = Int((clamped * 100).rounded(.down))
            guard bucket > lastBucket else { return false }
            lastBucket = bucket
            return true
        }
        if shouldPublish { handler(progress) }
    }
}

private final class BackupUploadActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var lastProgress = ProcessInfo.processInfo.systemUptime

    func markProgress() {
        lock.withLock { lastProgress = ProcessInfo.processInfo.systemUptime }
    }

    var secondsSinceProgress: TimeInterval {
        lock.withLock { max(0, ProcessInfo.processInfo.systemUptime - lastProgress) }
    }
}

private enum BackupUploadResolution: @unchecked Sendable {
    case success(PhotoUID)
    case failure(Error)
    case timedOut
    case cancelled
}

/// Requests the native cancellation of one upload token once. Every caller joins the same request.
final class BackupUploadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func request(uploader: any PhotoUploading, token: UUID) async {
        let task: Task<Void, Never> = lock.withLock {
            if let existing = self.task { return existing }
            let created = Task { await uploader.cancel(token: token) }
            self.task = created
            return created
        }
        await task.value
    }
}

private final class BackupUploadJoin: @unchecked Sendable {
    private let uploadTask: Task<Void, Never>
    private let race: BackupUploadRace
    private let cancellation = BackupUploadCancellation()
    private let uploader: any PhotoUploading
    private let token: UUID

    init(
        uploadTask: Task<Void, Never>,
        race: BackupUploadRace,
        uploader: any PhotoUploading,
        token: UUID
    ) {
        self.uploadTask = uploadTask
        self.race = race
        self.uploader = uploader
        self.token = token
    }

    func cancelAndJoin() async {
        uploadTask.cancel()
        if race.requestCancellation() {
            await cancellation.request(uploader: uploader, token: token)
        }
        await uploadTask.value
    }

    func settle() async {
        await uploadTask.value
    }
}

private final class BackupUploadRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BackupUploadResolution, Never>?
    private var resolution: BackupUploadResolution?

    func wait() async -> BackupUploadResolution {
        await withCheckedContinuation { continuation in
            let ready: BackupUploadResolution? = lock.withLock {
                if let resolution { return resolution }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    @discardableResult
    func resolve(_ value: BackupUploadResolution) -> Bool {
        let continuation: CheckedContinuation<BackupUploadResolution, Never>? = lock.withLock {
            guard resolution == nil else { return nil }
            resolution = value
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
        return true
    }

    @discardableResult
    func requestCancellation() -> Bool {
        let result:
            (
                continuation: CheckedContinuation<BackupUploadResolution, Never>?,
                shouldCancel: Bool
            ) = lock.withLock {
                let shouldCancel: Bool
                switch resolution {
                case nil:
                    resolution = .cancelled
                    shouldCancel = true
                case .cancelled, .timedOut:
                    shouldCancel = true
                case .success, .failure:
                    shouldCancel = false
                }
                defer { self.continuation = nil }
                return (self.continuation, shouldCancel)
            }
        result.continuation?.resume(returning: .cancelled)
        return result.shouldCancel
    }
}
