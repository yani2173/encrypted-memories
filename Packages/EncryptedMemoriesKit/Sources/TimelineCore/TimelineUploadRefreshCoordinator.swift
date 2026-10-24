import Foundation

public struct TimelineUploadRefreshAttempt: Sendable, Equatable {
    public let attempt: Int
    public let failureReason: TimelineRefreshFailureReason?
    public let decision: TimelineRefreshConvergenceDecision

    public init(
        attempt: Int,
        failureReason: TimelineRefreshFailureReason?,
        decision: TimelineRefreshConvergenceDecision
    ) {
        self.attempt = attempt
        self.failureReason = failureReason
        self.decision = decision
    }
}

/// Owns explicit refreshes and automatic upload convergence for one owner.
/// Explicit requests stay immediate. New automatic cycles run at most once per minute or at an explicit end.
public actor TimelineUploadRefreshCoordinator {
    public typealias Refresh = @Sendable (Int) async -> TimelineRefreshFailureReason?
    public typealias Observer = @Sendable (TimelineUploadRefreshAttempt) async -> Void

    private enum Cause: Sendable { case explicit, automatic }

    private struct Request: Sendable {
        let generation: UInt64
        let cause: Cause
        let refresh: Refresh
        let observer: Observer
    }

    private struct AutomaticCycle {
        var request: Request
        var attempt = 0
        var observation: TimelineUploadRefreshAttempt?
        var retryAt: ContinuousClock.Instant?
    }

    private struct FlushWaiter {
        let generation: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private let clock: TimelineRefreshClock
    private let policy: TimelineRefreshConvergencePolicy
    private var generation: UInt64 = 0
    private var nextWorkerID: UInt64 = 0
    private var activeWorkerID: UInt64?
    private var worker: Task<Void, Never>?
    private var latestRequest: Request?
    private var completedExplicitGeneration: UInt64?
    private var latestAutomaticRequest: Request?
    private var completedAutomaticGeneration: UInt64?
    private var nextAutomaticCycleAt: ContinuousClock.Instant?
    private var forcedAutomaticGeneration: UInt64?
    private var automaticWait: Task<Void, any Error>?
    private var flushWaiters: [FlushWaiter] = []

    public init(policy: TimelineRefreshConvergencePolicy = .init()) {
        self.policy = policy
        clock = .continuous
    }

    init(policy: TimelineRefreshConvergencePolicy = .init(), clock: TimelineRefreshClock) {
        self.policy = policy
        self.clock = clock
    }

    #if DEBUG
        func testingAutomaticState() -> (flushCount: Int, workerActive: Bool) {
            (flushWaiters.count, worker != nil)
        }
    #endif

    public func request(
        refresh: @escaping Refresh,
        observer: @escaping Observer = { _ in }
    ) {
        generation &+= 1
        latestRequest = Request(generation: generation, cause: .explicit, refresh: refresh, observer: observer)
        automaticWait?.cancel()
        startWorkerIfNeeded()
    }

    /// Accepts an automatic upload signal explicitly. Manual and explicit refreshes use `request`.
    public func requestAutomaticUpload(
        refresh: @escaping Refresh,
        observer: @escaping Observer = { _ in }
    ) {
        generation &+= 1
        latestAutomaticRequest = Request(
            generation: generation, cause: .automatic, refresh: refresh, observer: observer)
        startWorkerIfNeeded()
    }

    /// Flushes accepted automatic work without adding a signal. Call at the whole operation's end,
    /// outside this coordinator's refresh and observer closures, which belong to the joined work.
    public func flushAutomaticUploads() async {
        guard let request = latestAutomaticRequest,
            completedAutomaticGeneration != request.generation
        else { return }
        forcedAutomaticGeneration = max(forcedAutomaticGeneration ?? request.generation, request.generation)
        automaticWait?.cancel()
        startWorkerIfNeeded()
        await withCheckedContinuation { continuation in
            flushWaiters.append(.init(generation: request.generation, continuation: continuation))
        }
    }

    public func cancel() async {
        generation &+= 1
        let active = worker
        let retiredWaiters = flushWaiters
        active?.cancel()
        automaticWait?.cancel()
        activeWorkerID = nil
        worker = nil
        automaticWait = nil
        latestRequest = nil
        completedExplicitGeneration = nil
        latestAutomaticRequest = nil
        completedAutomaticGeneration = nil
        nextAutomaticCycleAt = nil
        forcedAutomaticGeneration = nil
        flushWaiters = []
        await active?.value
        for waiter in retiredWaiters { waiter.continuation.resume() }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        nextWorkerID &+= 1
        let workerID = nextWorkerID
        activeWorkerID = workerID
        worker = Task { await drain(workerID: workerID) }
    }

    private func drain(workerID: UInt64) async {
        defer {
            if activeWorkerID == workerID {
                activeWorkerID = nil
                worker = nil
            }
        }

        var automaticCycle: AutomaticCycle?
        while !Task.isCancelled, activeWorkerID == workerID {
            if let explicit = latestRequest, completedExplicitGeneration != explicit.generation {
                if await runCycle(explicit, workerID: workerID) { complete(explicit) }
                continue
            }

            if var cycle = automaticCycle {
                if let observation = cycle.observation {
                    await cycle.request.observer(observation)
                    guard !Task.isCancelled, activeWorkerID == workerID else { return }
                    cycle.observation = nil
                    if case .retry(let delay) = observation.decision {
                        cycle.retryAt = clock.now() + delay
                        automaticCycle = cycle
                    } else {
                        complete(cycle.request)
                        automaticCycle = nil
                    }
                    continue
                }

                if let retryAt = cycle.retryAt {
                    if clock.now() < retryAt {
                        let wait = Task { try await clock.sleepUntil(retryAt) }
                        automaticWait = wait
                        do {
                            try await wait.value
                        } catch {
                            if !wait.isCancelled {
                                cycle.observation = .init(
                                    attempt: cycle.attempt, failureReason: .other, decision: .failed)
                                cycle.retryAt = nil
                            }
                        }
                        guard !Task.isCancelled, activeWorkerID == workerID else { return }
                        automaticWait = nil
                        automaticCycle = cycle
                        continue
                    }
                    cycle.retryAt = nil
                    cycle.attempt += 1
                    guard let latest = latestAutomaticRequest else { return }
                    cycle.request = latest
                }

                let failure = await cycle.request.refresh(cycle.attempt)
                guard !Task.isCancelled, activeWorkerID == workerID else { return }
                cycle.observation = .init(
                    attempt: cycle.attempt, failureReason: failure,
                    decision: policy.decision(after: failure, attempt: cycle.attempt))
                automaticCycle = cycle
                continue
            }

            if let automatic = latestAutomaticRequest,
                completedAutomaticGeneration != automatic.generation
            {
                if forcedAutomaticGeneration == nil, let nextAutomaticCycleAt,
                    clock.now() < nextAutomaticCycleAt
                {
                    let wait = Task { try await clock.sleepUntil(nextAutomaticCycleAt) }
                    automaticWait = wait
                    do {
                        try await wait.value
                    } catch is CancellationError {
                        // An explicit request or end wakes this wait; cancel() also cancels the worker.
                    } catch {
                        if !Task.isCancelled, isCurrent(automatic, workerID: workerID) {
                            await automatic.observer(.init(attempt: 0, failureReason: .other, decision: .failed))
                            if !Task.isCancelled, isCurrent(automatic, workerID: workerID) {
                                complete(automatic)
                            }
                        }
                    }
                    if activeWorkerID == workerID { automaticWait = nil }
                    continue
                }
                automaticCycle = AutomaticCycle(request: automatic)
                nextAutomaticCycleAt = clock.now() + .seconds(60)
            } else {
                break
            }
        }
    }

    private func runCycle(_ request: Request, workerID: UInt64) async -> Bool {
        var attempt = 0
        while !Task.isCancelled {
            guard isCurrent(request, workerID: workerID) else { return false }
            let failure = await request.refresh(attempt)
            guard !Task.isCancelled, isCurrent(request, workerID: workerID) else { return false }
            let decision = policy.decision(after: failure, attempt: attempt)
            await request.observer(.init(attempt: attempt, failureReason: failure, decision: decision))
            guard !Task.isCancelled, isCurrent(request, workerID: workerID) else { return false }
            guard case .retry(let delay) = decision else { return true }
            do {
                try await clock.sleep(delay)
            } catch {
                guard !Task.isCancelled, isCurrent(request, workerID: workerID) else { return false }
                await request.observer(.init(attempt: attempt, failureReason: .other, decision: .failed))
                return !Task.isCancelled && isCurrent(request, workerID: workerID)
            }
            attempt += 1
        }
        return false
    }

    private func isCurrent(_ request: Request, workerID: UInt64) -> Bool {
        guard activeWorkerID == workerID else { return false }
        switch request.cause {
        case .explicit: return latestRequest?.generation == request.generation
        case .automatic: return latestAutomaticRequest?.generation == request.generation
        }
    }

    private func complete(_ request: Request) {
        switch request.cause {
        case .explicit:
            completedExplicitGeneration = request.generation
        case .automatic:
            completedAutomaticGeneration = request.generation
            if let target = forcedAutomaticGeneration, target <= request.generation {
                forcedAutomaticGeneration = nil
            }
            let waiters = flushWaiters
            flushWaiters = []
            for waiter in waiters {
                if waiter.generation <= request.generation {
                    waiter.continuation.resume()
                } else {
                    flushWaiters.append(waiter)
                }
            }
        }
    }
}
