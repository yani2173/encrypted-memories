import Foundation
import PhotosCore

/// Internal monotonic time and suspension dependency. Public owners use the native clock.
struct TimelineRefreshClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleep: @Sendable (Duration) async throws -> Void
    let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void

    static let continuous = TimelineRefreshClock(
        now: { ContinuousClock.now },
        sleep: { try await Task.sleep(for: $0) },
        sleepUntil: { try await ContinuousClock().sleep(until: $0) }
    )
}

/// Shared foreground polling policy for remote library mutations. The probe is deliberately cheap
/// (an opaque server event token); a full timeline refresh runs only after that token changes.
public struct LibraryChangePollingPolicy: Sendable, Equatable {
    public let interval: Duration
    public let refreshRetryInterval: Duration
    /// The longest wait between two loads of a library that has not caught up yet.
    public let maxRefreshRetryInterval: Duration
    public let failureInterval: Duration
    /// Nil preserves immediate change handling for custom polling policies.
    public let trailingQuietInterval: Duration?
    public let maxTrailingInterval: Duration

    public init(
        interval: Duration, refreshRetryInterval: Duration? = nil, maxRefreshRetryInterval: Duration? = nil,
        failureInterval: Duration,
        trailingQuietInterval: Duration? = nil,
        maxTrailingInterval: Duration = .seconds(60)
    ) {
        self.interval = interval
        self.refreshRetryInterval = refreshRetryInterval ?? interval
        self.maxRefreshRetryInterval = max(
            maxRefreshRetryInterval ?? self.refreshRetryInterval, self.refreshRetryInterval)
        self.failureInterval = failureInterval
        self.trailingQuietInterval = trailingQuietInterval
        self.maxTrailingInterval = maxTrailingInterval
    }

    /// Probes every five seconds and refreshes the first isolated change immediately after detection.
    /// Trailing changes wait for twenty-five seconds of quiet or sixty seconds from the first deferred change.
    /// Inventory convergence retries retain their bounded exponential backoff.
    public static let foreground = LibraryChangePollingPolicy(
        interval: .seconds(5),
        refreshRetryInterval: .seconds(5),
        maxRefreshRetryInterval: .seconds(30),
        failureInterval: .seconds(30),
        trailingQuietInterval: .seconds(25),
        maxTrailingInterval: .seconds(60)
    )

    /// The wait before the next load, after `retries` loads in a row saw a library that had not caught up.
    public func refreshRetryDelay(afterRetries retries: Int) -> Duration {
        var delay = refreshRetryInterval
        for _ in 1..<max(1, retries) {
            guard delay < maxRefreshRetryInterval else { break }
            delay *= 2
        }
        return min(delay, maxRefreshRetryInterval)
    }
}

/// Counts the loads in a row that saw a library behind one event token. A newer token starts the count again, so
/// its first retry waits the shortest time.
struct LibraryChangeRetryCount: Equatable {
    private(set) var token: String?
    private(set) var retries = 0

    mutating func nextDelay(for token: String, policy: LibraryChangePollingPolicy) -> Duration {
        if token != self.token {
            self.token = token
            retries = 0
        }
        retries += 1
        return policy.refreshRetryDelay(afterRetries: retries)
    }

    mutating func reset() {
        token = nil
        retries = 0
    }
}

/// Result of the authoritative refresh requested after a change-token transition. A terminal result retires
/// the monitor before it invokes the host callback, including when scope loss appears during the full load.
public enum LibraryChangeRefreshOutcome: Sendable, Equatable {
    /// Only this revision belongs to the published projection. Nil leaves monitoring unacknowledged.
    case refreshed(token: String?)
    /// The refresh succeeded on a route that cannot confirm a whole-library revision (a filtered route).
    /// The monitor leaves its baseline and backoff alone and waits for a newer token or `resumeDeferredRefresh()`.
    case refreshedWithoutRevision
    case retry
    case terminal
}

/// One platform-neutral monitor shared by macOS, iOS and iPadOS. Hosts only express lifecycle by
/// starting/stopping it; token comparison, cadence, failure backoff and refresh coalescing live here.
public actor LibraryChangeMonitor {
    private struct StartRequest: Sendable {
        let provider: any LibraryChangeTokenProvider
        let policy: LibraryChangePollingPolicy
        let isActive: Bool
        let resetBaseline: Bool
        let initialToken: String?
        let onChange: @Sendable () async -> LibraryChangeRefreshOutcome
        let onTerminal: @Sendable (any LibraryChangeTerminalError) async -> Void
    }

    private enum DesiredLifecycle: Sendable {
        case stopped(resetBaseline: Bool)
        case start(StartRequest)
        case active
    }

    private let clock: TimelineRefreshClock
    private var task: Task<Void, Never>?
    private var activeTaskID: UInt64?
    private var retiringTaskID: UInt64?
    private var nextTaskID: UInt64 = 0
    private var desiredLifecycle: DesiredLifecycle = .stopped(resetBaseline: false)
    private var lastToken: String?
    /// The token whose refresh succeeded on a route that could not confirm it. It is not refreshed again.
    private var deferredToken: String?
    /// Counts host resumes, so a resume during a refresh keeps that refresh's token pending.
    private var resumeGeneration: UInt64 = 0

    public init() {
        clock = .continuous
    }

    init(clock: TimelineRefreshClock) {
        self.clock = clock
    }

    #if DEBUG
        func testingBaseline() -> String? { lastToken }
    #endif

    public func start(
        provider: any LibraryChangeTokenProvider,
        policy: LibraryChangePollingPolicy = .foreground,
        isActive: Bool = true,
        initialToken: String? = nil,
        onTerminal: @Sendable @escaping (any LibraryChangeTerminalError) async -> Void = { _ in },
        onChange: @Sendable @escaping () async -> LibraryChangeRefreshOutcome
    ) {
        // Repeated starts remain idempotent while a monitor is active. A start that arrives while stop,
        // restart or reset is joining the old task becomes the desired next state instead of being dropped.
        guard task == nil || retiringTaskID != nil else { return }
        desiredLifecycle = .start(
            StartRequest(
                provider: provider,
                policy: policy,
                isActive: isActive,
                resetBaseline: false,
                initialToken: initialToken,
                onChange: onChange,
                onTerminal: onTerminal
            ))
        applyDesiredLifecycleIfPossible()
    }

    private func launch(_ request: StartRequest) {
        if request.resetBaseline {
            lastToken = nil
            deferredToken = nil
        }
        // A startup seed fills only an unknown baseline. Reappearing views must not overwrite a newer token the
        // same monitor already observed while the app was running.
        if lastToken == nil, let initialToken = request.initialToken { lastToken = initialToken }
        // Inactive startup still installs the published snapshot's seed. Foreground reuses it.
        guard request.isActive else {
            desiredLifecycle = .stopped(resetBaseline: false)
            return
        }
        let delayFirstProbe = lastToken != nil
        nextTaskID &+= 1
        let taskID = nextTaskID
        activeTaskID = taskID
        desiredLifecycle = .active
        task = Task {
            // A validated/full load just observed this revision. Polling it again immediately adds an API call
            // to the launch critical path without increasing correctness; the seeded baseline still detects
            // every later mutation on the normal foreground cadence.
            if delayFirstProbe {
                do {
                    try await clock.sleep(request.policy.interval)
                } catch {
                    return
                }
            }
            var retryCount = LibraryChangeRetryCount()
            var observedToken = lastToken
            var lastChangeAt: ContinuousClock.Instant?
            var firstDeferredAt: ContinuousClock.Instant?
            while !Task.isCancelled {
                do {
                    let token = try await request.provider.libraryChangeToken()
                    try Task.checkCancellation()
                    if let lastToken, token != lastToken {
                        // A filtered route already refreshed for this token. Wait for a newer token or a resume.
                        if token == deferredToken {
                            try await clock.sleep(request.policy.interval)
                            continue
                        }
                        if let quiet = request.policy.trailingQuietInterval {
                            let now = clock.now()
                            if token != observedToken {
                                if let previousChange = lastChangeAt, now - previousChange < quiet,
                                    firstDeferredAt == nil
                                {
                                    firstDeferredAt = now
                                }
                                observedToken = token
                                lastChangeAt = now
                            }
                            if let firstDeferredAt, let lastChangeAt {
                                let deadline = min(
                                    lastChangeAt + quiet, firstDeferredAt + request.policy.maxTrailingInterval)
                                if now < deadline {
                                    try await clock.sleepUntil(min(now + request.policy.interval, deadline))
                                    continue
                                }
                            }
                        }
                        try Task.checkCancellation()
                        let generation = resumeGeneration
                        switch await request.onChange() {
                        case .refreshedWithoutRevision:
                            try Task.checkCancellation()
                            firstDeferredAt = nil
                            if generation == resumeGeneration { deferredToken = token }
                            try await clock.sleep(request.policy.interval)
                            continue
                        case .refreshed(let publishedToken):
                            try Task.checkCancellation()
                            deferredToken = nil
                            if let publishedToken { self.lastToken = publishedToken }
                            guard publishedToken == token else {
                                try? await clock.sleep(retryCount.nextDelay(for: token, policy: request.policy))
                                continue
                            }
                            retryCount.reset()
                            firstDeferredAt = nil
                            try await clock.sleep(request.policy.interval)
                            continue
                        case .retry:
                            // A successful token probe with an inventory that has not converged is not a
                            // transport failure. Keep the old token and wait longer after each such load.
                            try? await clock.sleep(retryCount.nextDelay(for: token, policy: request.policy))
                            continue
                        case .terminal:
                            await handleTerminal(
                                taskID: taskID,
                                error: LibraryChangeRefreshTerminalError(),
                                onTerminal: request.onTerminal
                            )
                            return
                        }
                    }
                    try Task.checkCancellation()
                    retryCount.reset()
                    firstDeferredAt = nil
                    observedToken = token
                    lastToken = token
                    try await clock.sleep(request.policy.interval)
                } catch is CancellationError {
                    break
                } catch let error as any LibraryChangeTerminalError {
                    await handleTerminal(
                        taskID: taskID,
                        error: error,
                        onTerminal: request.onTerminal
                    )
                    return
                } catch {
                    try? await clock.sleep(request.policy.failureInterval)
                }
            }
        }
    }

    /// Lets the next probe refresh again for a token that a route-limited refresh deferred. A host calls this
    /// when its route can confirm whole-library revisions again.
    public func resumeDeferredRefresh() {
        deferredToken = nil
        resumeGeneration &+= 1
    }

    public func stop() async {
        desiredLifecycle = .stopped(resetBaseline: false)
        await retireCurrentTask()
    }

    public func restart(
        provider: any LibraryChangeTokenProvider,
        policy: LibraryChangePollingPolicy = .foreground,
        isActive: Bool = true,
        resetBaseline: Bool = false,
        initialToken: String? = nil,
        onTerminal: @Sendable @escaping (any LibraryChangeTerminalError) async -> Void = { _ in },
        onChange: @Sendable @escaping () async -> LibraryChangeRefreshOutcome
    ) async {
        desiredLifecycle = .start(
            StartRequest(
                provider: provider,
                policy: policy,
                isActive: isActive,
                resetBaseline: resetBaseline,
                initialToken: initialToken,
                onChange: onChange,
                onTerminal: onTerminal
            ))
        await retireCurrentTask()
    }

    public func reset() async {
        desiredLifecycle = .stopped(resetBaseline: true)
        await retireCurrentTask()
    }

    /// Retires a terminal task before notifying its host. The callback can therefore reset or restart this
    /// monitor without joining the task that is currently invoking it. Scope loss invalidates the baseline.
    private func handleTerminal(
        taskID: UInt64,
        error: any LibraryChangeTerminalError,
        onTerminal: @Sendable (any LibraryChangeTerminalError) async -> Void
    ) async {
        guard activeTaskID == taskID, retiringTaskID == nil else { return }
        task = nil
        activeTaskID = nil
        lastToken = nil
        deferredToken = nil
        desiredLifecycle = .stopped(resetBaseline: false)
        await onTerminal(error)
    }

    private func retireCurrentTask() async {
        let retiringTask = task
        guard let retiringTask, let taskID = activeTaskID else {
            task = nil
            activeTaskID = nil
            retiringTaskID = nil
            applyDesiredLifecycleIfPossible()
            return
        }

        retiringTaskID = taskID
        retiringTask.cancel()
        await retiringTask.value

        // Several lifecycle callers can join the same task. Only the first completion for that exact task
        // applies the latest desired state; older completions must not clear a replacement task.
        guard retiringTaskID == taskID, activeTaskID == taskID else { return }
        task = nil
        activeTaskID = nil
        retiringTaskID = nil
        applyDesiredLifecycleIfPossible()
    }

    private func applyDesiredLifecycleIfPossible() {
        guard task == nil, retiringTaskID == nil else { return }
        switch desiredLifecycle {
        case .stopped(let resetBaseline):
            if resetBaseline {
                lastToken = nil
                deferredToken = nil
            }
            desiredLifecycle = .stopped(resetBaseline: false)
        case .start(let request):
            launch(request)
        case .active:
            break
        }
    }
}

private struct LibraryChangeRefreshTerminalError: LibraryChangeTerminalError {}
