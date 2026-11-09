import Foundation

/// Runtime-only context needed to turn durable queue truth into the shared user-facing status.
/// It deliberately contains no platform types and no asset identifiers.
public struct BackupStatusProjectionContext: Sendable, Equatable {
    public var isScanning: Bool
    public var isRunning: Bool
    public var isUserPaused: Bool
    public var executionOpportunityIssue: BackupExecutionOpportunityIssue?

    public init(
        isScanning: Bool = false,
        isRunning: Bool = false,
        isUserPaused: Bool = false,
        executionOpportunityIssue: BackupExecutionOpportunityIssue? = nil
    ) {
        self.isScanning = isScanning
        self.isRunning = isRunning
        self.isUserPaused = isUserPaused
        self.executionOpportunityIssue = executionOpportunityIssue
    }
}

/// Immutable handoff from the off-main projector to a platform UI model.
public struct BackupStatusProjection: Sendable, Equatable {
    public let generation: UUID
    public let revision: UInt64
    public let progress: BackupSyncProgress
    public let status: BackupStatus

    public init(
        generation: UUID,
        revision: UInt64,
        progress: BackupSyncProgress,
        status: BackupStatus
    ) {
        self.generation = generation
        self.revision = revision
        self.progress = progress
        self.status = status
    }
}

/// Reads SQLite queue truth and coalesces high-frequency runner callbacks away from `MainActor`.
///
/// The callback seam is synchronous by design: callers only put the newest ephemeral runner value
/// into a one-element stream. This actor performs every durable `summary()`/outstanding-work read,
/// then delivers one immutable projection to the main actor. Phase changes, terminal/error states,
/// and queue drain publish immediately; ordinary count/byte ticks publish at most every 150 ms.
public actor BackupStatusProjector {
    public typealias Handler = @MainActor @Sendable (BackupStatusProjection) -> Void

    private struct RunnerEvent: Sendable {
        let generation: UUID
        let progress: BackupSyncProgress
        let sequence: UInt64
    }

    private let queue: any UploadBackupSyncQueueStore
    private let coalescingInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let stream: AsyncStream<RunnerEvent>
    private nonisolated let continuation: AsyncStream<RunnerEvent>.Continuation

    /// Tracks the runner callback sequence number. The sequence is handed out and the matching
    /// stream yield is performed in one locked section, so the sequence order is also the yield
    /// order, which the drain barrier in `drainSubmittedEvents` relies on.
    private final class SubmissionCounters: @unchecked Sendable {
        private let lock = NSLock()
        private var _current = UInt64(0)
        func withNextSequence(_ body: (UInt64) -> Void) {
            lock.withLock {
                _current += 1
                body(_current)
            }
        }
        var current: UInt64 { lock.withLock { _current } }
    }

    private let counters = SubmissionCounters()

    private var generation = UUID()
    private var contextRevision: UInt64 = 0
    private var context = BackupStatusProjectionContext()
    private var handler: Handler?
    private var streamTask: Task<Void, Never>?
    private var delayedPublicationTask: Task<Void, Never>?
    private var latestRunnerProgress: BackupSyncProgress?
    private var lastRawPhase: BackupStatus.Phase?
    private var lastPublishedAt = Date.distantPast
    private var speedEstimator = BackupUploadSpeedEstimator()
    private var lastConsumedSequence: UInt64 = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    /// Identifies the current stream consumer; a new `start` bumps the epoch, so a drain that
    /// began against the previous consumer stops waiting instead of blocking a later session.
    private var streamConsumerEpoch: UInt64 = 0
    /// False once the current consumer left its loop, even when its task handle is not cancelled.
    private var streamConsumerActive = false
    #if DEBUG
        private var statusIngestionGateForTesting: (@Sendable () async -> Void)?
        private var statusIngestionObserverForTesting: (@Sendable () async -> Void)?
    #endif

    public init(
        queue: any UploadBackupSyncQueueStore,
        coalescingInterval: TimeInterval = 0.15,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.queue = queue
        self.coalescingInterval = max(0, coalescingInterval)
        self.now = now
        let pair = AsyncStream.makeStream(
            of: RunnerEvent.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    /// Safe to call directly from `BackupSyncRunner`'s synchronous progress callback. No task is
    /// allocated per callback and an overwhelmed UI path retains only the newest ephemeral value.
    public nonisolated func submit(_ progress: BackupSyncProgress, generation: UUID) {
        counters.withNextSequence { sequence in
            continuation.yield(RunnerEvent(generation: generation, progress: progress, sequence: sequence))
        }
    }

    #if DEBUG
        /// Test hook: holds each ingested stream event at the consumer before projection.
        public func setIngestionGateForTesting(_ gate: (@Sendable () async -> Void)?) {
            statusIngestionGateForTesting = gate
        }

        /// Test hook: called on the actor after each stream event is fully ingested and published.
        public func setIngestionObserverForTesting(_ observer: (@Sendable () async -> Void)?) {
            statusIngestionObserverForTesting = observer
        }
    #endif

    /// Waits on the current actor context until every runner event already submitted to this
    /// projector has been fully ingested (published or discarded) by the stream consumer, or
    /// until that consumer stops consuming events entirely. The `completeSyncRun` barrier
    /// prevents a starved consumer from applying a straggler snapshot after a pass has already
    /// decided its next attempt date.
    public func drainSubmittedEvents() async {
        let target = counters.current
        let consumerEpoch = streamConsumerEpoch
        guard lastConsumedSequence < target, streamConsumerActive,
            let consumer = streamTask, !consumer.isCancelled
        else { return }
        while lastConsumedSequence < target {
            await withCheckedContinuation { continuation in
                drainWaiters.append(continuation)
            }
            // Wake-ups can also come from a consumer that stopped or was replaced meanwhile.
            guard streamConsumerEpoch == consumerEpoch, streamConsumerActive,
                let active = streamTask, !active.isCancelled
            else { return }
        }
    }

    /// Starts one long-lived stream consumer for an account session and immediately projects the
    /// durable queue. A generation change invalidates every event still buffered from the old session.
    public func start(
        generation: UUID,
        revision: UInt64 = 0,
        context: BackupStatusProjectionContext,
        handler: @escaping Handler
    ) async {
        let previousStreamTask = streamTask
        let previousDelayedTask = delayedPublicationTask
        previousStreamTask?.cancel()
        previousDelayedTask?.cancel()
        await previousStreamTask?.value
        await previousDelayedTask?.value
        streamTask = nil
        delayedPublicationTask = nil
        self.generation = generation
        contextRevision = revision
        self.context = context
        self.handler = handler
        latestRunnerProgress = nil
        lastRawPhase = nil
        lastPublishedAt = .distantPast
        speedEstimator.reset()

        let stream = self.stream
        streamConsumerEpoch += 1
        let epoch = streamConsumerEpoch
        streamConsumerActive = true
        streamTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                await self.consumeRunnerEvent(event)
            }
            await self?.consumerDidExit(epoch: epoch)
        }
        _ = await publishNow()
    }

    /// Explicit durable refresh for launch/finalization and the low-frequency one-second truth
    /// heartbeat. The queue read executes on this actor, never on `MainActor`.
    @discardableResult
    public func projectNow(
        context: BackupStatusProjectionContext,
        generation: UUID,
        revision: UInt64
    ) async -> BackupStatusProjection? {
        guard generation == self.generation, revision >= contextRevision else { return nil }
        if self.context.isRunning != context.isRunning {
            lastRawPhase = nil
        }
        self.context = context
        contextRevision = revision
        delayedPublicationTask?.cancel()
        delayedPublicationTask = nil
        return await publishNow()
    }

    public func stop() async {
        let activeStreamTask = streamTask
        let activeDelayedTask = delayedPublicationTask
        activeStreamTask?.cancel()
        activeDelayedTask?.cancel()
        streamTask = nil
        delayedPublicationTask = nil
        await activeStreamTask?.value
        await activeDelayedTask?.value
        handler = nil
        latestRunnerProgress = nil
        generation = UUID()
        contextRevision = 0
    }

    /// Single entry point of the stream consumer: gate, ingest, notify.
    private func consumeRunnerEvent(_ event: RunnerEvent) async {
        #if DEBUG
            if let gate = statusIngestionGateForTesting { await gate() }
        #endif
        await ingest(event)
        #if DEBUG
            await statusIngestionObserverForTesting?()
        #endif
    }

    /// Advances the drain barrier and wakes every waiter after a stream event settles.
    private func noteConsumed(_ sequence: UInt64) {
        lastConsumedSequence = max(lastConsumedSequence, sequence)
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Wakes every drain waiter after the stream consumer stops consuming, without advancing
    /// the drain barrier: the waiter re-checks consumer liveness and returns if it stopped.
    private func consumerDidExit(epoch: UInt64) {
        guard epoch == streamConsumerEpoch else { return }
        streamConsumerActive = false
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func ingest(_ event: RunnerEvent) async {
        defer { noteConsumed(event.sequence) }
        guard event.generation == generation else { return }
        let previous = latestRunnerProgress
        latestRunnerProgress = event.progress

        let rawStatus = BackupStatus(
            progress: event.progress,
            isScanning: context.isScanning,
            isUserPaused: context.isUserPaused,
            executionOpportunityIssue: context.executionOpportunityIssue
        )
        if Self.sendsBytes(rawStatus.phase) {
            speedEstimator.record(bytes: event.progress.transferredByteCount, at: now())
        } else {
            speedEstimator.reset()
        }
        let phaseChanged = rawStatus.phase != lastRawPhase
        lastRawPhase = rawStatus.phase
        let issueChanged =
            previous?.remoteIndexPreparationIssue != event.progress.remoteIndexPreparationIssue
            || previous?.failed != event.progress.failed
            || previous?.sourceMissing != event.progress.sourceMissing
        let previousOutstanding =
            (previous?.waiting ?? 0) + (previous?.checking ?? 0)
            + (previous?.uploading ?? 0) + (previous?.blocked ?? 0) + (previous?.pendingSourceRechecks ?? 0)
        let currentOutstanding =
            event.progress.waiting + event.progress.checking
            + event.progress.uploading + event.progress.blocked + event.progress.pendingSourceRechecks
        let drained = previousOutstanding > 0 && currentOutstanding == 0
        let terminal = !event.progress.isRunning

        if phaseChanged || issueChanged || drained || terminal {
            delayedPublicationTask?.cancel()
            delayedPublicationTask = nil
            _ = await publishNow()
        } else {
            scheduleCoalescedPublication()
        }
    }

    private func scheduleCoalescedPublication() {
        guard delayedPublicationTask == nil else { return }
        let elapsed = now().timeIntervalSince(lastPublishedAt)
        let delay = max(0, coalescingInterval - elapsed)
        delayedPublicationTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            await self.flushCoalescedPublication()
        }
    }

    private func flushCoalescedPublication() async {
        delayedPublicationTask = nil
        _ = await publishNow()
    }

    private func publishNow() async -> BackupStatusProjection? {
        guard queue.isOperational() else { return nil }
        guard let summary = queue.summary() else { return nil }
        guard queue.isOperational() else { return nil }

        var progress = latestRunnerProgress ?? BackupSyncProgress()
        progress.total = summary.total
        progress.waiting = summary.waiting
        progress.uploadQueued = summary.queuedForUpload
        progress.checking = summary.checkingActive
        progress.uploading = summary.uploadingActive
        progress.uploaded = summary.uploaded
        progress.alreadyBackedUp = summary.alreadyBackedUp
        progress.skippedRemoteDeletions = summary.skippedRemoteDeletions
        progress.sourceMissing = summary.sourceMissing
        progress.blocked = summary.blocked
        progress.failed = summary.failed
        progress.dismissedFailures = summary.dismissedFailures
        progress.pendingSourceRechecks = summary.pendingSourceRechecks
        progress.paused = summary.paused
        // A Photo Library pass repeatedly invokes short eligible-only runner drains while its scan
        // runs concurrently. The controller's run context is therefore the stable activity truth;
        // Mirroring each micro-drain's terminal callback would flicker between checking and waiting.
        progress.isRunning = context.isRunning
        // Byte/item liveness belongs to active queue rows, not to the controller's wider orchestration
        // lifetime. The scan/reconcile task can remain alive briefly after the final row settles; retaining
        // its last transfer snapshot would render "N of N", a spinner, and a stale percentage together.
        if summary.waiting + summary.active + summary.blocked == 0 {
            progress.currentItemName = nil
            progress.activeTransfer = nil
            progress.activeExecutionItemEquivalents = 0
        }
        if !context.isRunning {
            progress.currentItemName = nil
            progress.remoteIndexPreparation = nil
            progress.activeTransfer = nil
            progress.activeExecutionItemEquivalents = 0
        }

        progress.remoteIndexPreparationIssue =
            queue.runtimeIssue(for: .remoteIndexPreparation)
            ?? progress.remoteIndexPreparationIssue
        progress.remoteIndexPreparationFailed = progress.remoteIndexPreparationIssue != nil
        progress.outstanding = outstandingSnapshot(summary: summary, isRunning: context.isRunning)
        if let issue = progress.remoteIndexPreparationIssue {
            progress.outstanding = BackupOutstandingSnapshot(
                count: max(1, progress.outstanding.count),
                issue: issue.kind,
                nextAttemptAt: issue.nextAttemptAt
            )
        }

        var status = BackupStatus(
            progress: progress,
            isScanning: context.isScanning,
            isUserPaused: context.isUserPaused,
            executionOpportunityIssue: context.executionOpportunityIssue
        )
        if Self.sendsBytes(status.phase) {
            status.uploadSpeedBytesPerSecond = speedEstimator.speed(at: now())
        } else {
            speedEstimator.reset()
        }
        let projection = BackupStatusProjection(
            generation: generation,
            revision: contextRevision,
            progress: progress,
            status: status
        )
        lastPublishedAt = now()
        if let handler {
            await handler(projection)
        }
        return projection
    }

    /// Only these phases can show an upload speed. Every other phase makes the next resume start fresh.
    private static func sendsBytes(_ phase: BackupStatus.Phase) -> Bool {
        phase == .checking || phase == .uploading
    }

    private func outstandingSnapshot(
        summary: UploadBackupSyncQueueSummary,
        isRunning: Bool
    ) -> BackupOutstandingSnapshot {
        let count = summary.waiting + summary.active + summary.blocked + summary.pendingSourceRechecks
        guard count > 0 else { return BackupOutstandingSnapshot() }
        guard !isRunning else { return BackupOutstandingSnapshot(count: count) }

        var candidates: [(Date, BackupIssueKind)] = []
        if let entry = queue.earliestRunnableEntry() {
            let record = BackupIssueRecord.decode(entry.lastError)
            candidates.append(
                (
                    BackupFailedItem.effectiveNextAttempt(record, entry: entry) ?? entry.updatedAt,
                    record?.kind ?? .unknown
                ))
        }
        if let entry = queue.earliestEntry(in: .blockedByDraft) {
            let record = BackupIssueRecord.decode(entry.lastError)
            if let due = BackupFailedItem.effectiveNextAttempt(record, entry: entry) {
                candidates.append((due, .remoteDraft))
            }
        }
        let earliest = candidates.min { $0.0 < $1.0 }
        return BackupOutstandingSnapshot(count: count, issue: earliest?.1, nextAttemptAt: earliest?.0)
    }
}
