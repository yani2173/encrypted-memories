import Foundation

/// Submits the requests of one OS background task. Before iOS 27 the scheduler's old call runs at once. From iOS 27
/// the new call runs off the main thread, because its header forbids the main thread.
@MainActor
public final class BackgroundTaskRequestSubmitter {
    private let cancelRequest: @MainActor () -> Void
    private let onErrorAfterCancel: @MainActor (any Error) -> Void
    private let predecessorDeadline: @Sendable () async -> Void
    private let diagnostics: PhotoDiagnostics
    /// Counts the cancels. A request whose count changed while it was on its way may have landed after the cancel.
    private var cancelGeneration = 0
    private var lastSubmission: Task<Void, Never>?
    /// Every submission that has not ended yet, by the order of its submission.
    private var unfinished: [Int: Task<Void, Never>] = [:]
    private var submissionCount = 0
    /// The cancel generation of the newest request sent to the scheduler. A request that a cancel overtook cancels again
    /// unless the newest request sent belongs to the current generation: then a restarted task has its own request,
    /// which has the same identifier, and the cancel would remove it.
    private var newestSentGeneration: Int?

    /// `cancelRequest` removes the pending request of the task from the scheduler. `onErrorAfterCancel` gets the error of
    /// a request that a cancel overtook, which reports to nobody else. A request waits for the one before it until
    /// `predecessorDeadline` at the latest, by default `endOfWindowWaitLimit`.
    public init(
        cancelRequest: @escaping @MainActor () -> Void,
        onErrorAfterCancel: @escaping @MainActor (any Error) -> Void,
        predecessorDeadline: @escaping @Sendable () async -> Void = BackgroundTaskRequestSubmitter.defaultDeadline,
        diagnostics: PhotoDiagnostics = .shared
    ) {
        self.cancelRequest = cancelRequest
        self.onErrorAfterCancel = onErrorAfterCancel
        self.predecessorDeadline = predecessorDeadline
        self.diagnostics = diagnostics
    }

    /// The longest time that the end of a window waits for its pending requests, and that a request waits for the one
    /// before it. iOS 27 may report a request after an arbitrary delay, and a window must end before the OS ends the
    /// process.
    public static let endOfWindowWaitLimit: Duration = .seconds(5)
    public static let defaultDeadline: @Sendable () async -> Void = {
        try? await Task.sleep(for: BackgroundTaskRequestSubmitter.endOfWindowWaitLimit)
    }
    /// Counts the window ends whose wait for the requests ran into the limit.
    static let endWaitTimedOutKey = "backgroundWindows.endWaitTimedOut"
    /// Counts the requests that went ahead of a request before them that had not returned within the limit.
    static let wentAheadKey = "backgroundWindows.requestWentAheadOfALateOne"

    /// Submits one request. `offMainThread` is the iOS 27 call, nil before iOS 27; `blocking` is the old call.
    /// `completion` gets the scheduler's error, or nil. Requests of the new call reach the scheduler in this order, so
    /// an older request never replaces a newer one, unless the older one has not returned within the limit: then the
    /// newer one goes ahead. A request that a cancel overtook reports no completion: its error goes to
    /// `onErrorAfterCancel`, and no caller waits for its completion.
    public func submit(
        blocking: () throws -> Void,
        offMainThread: (@Sendable () async throws -> Void)?,
        completion: @escaping @MainActor ((any Error)?) -> Void
    ) {
        guard let offMainThread else {
            do {
                try blocking()
                completion(nil)
            } catch {
                completion(error)
            }
            return
        }
        let generation = cancelGeneration
        let previous = lastSubmission
        let id = submissionCount
        submissionCount += 1
        let submission = Task { [weak self, predecessorDeadline, diagnostics] in
            defer { self?.unfinished[id] = nil }
            if let previous {
                let bound = Deadline(predecessorDeadline)
                if !(await bound.race(previous)) { diagnostics.increment(Self.wentAheadKey) }
                bound.cancel()
            }
            // A cancel came while this request waited for the one before it: the request is never sent.
            guard let self, self.cancelGeneration == generation else { return }
            self.newestSentGeneration = generation
            let error = await Task.detached { () -> (any Error)? in
                do {
                    try await offMainThread()
                    return nil
                } catch {
                    return error
                }
            }.value
            guard self.cancelGeneration == generation else {
                // The cancel came while this request was on its way, so the request may have landed after it.
                if self.newestSentGeneration != self.cancelGeneration { self.cancelRequest() }
                if let error { self.onErrorAfterCancel(error) }
                return
            }
            completion(error)
        }
        lastSubmission = submission
        unfinished[id] = submission
    }

    /// Waits until every submission that has not ended reached the scheduler and reported, or was dropped after a
    /// cancel: also one that a later request went ahead of, and one submitted during the wait. The whole wait ends at
    /// the one `deadline`, by default after `endOfWindowWaitLimit`. Returns false when the deadline ended it.
    @discardableResult
    public func pendingSubmissionsEnded(
        deadline: @escaping @Sendable () async -> Void = BackgroundTaskRequestSubmitter.defaultDeadline
    ) async -> Bool {
        let shared = Deadline(deadline)
        defer { shared.cancel() }
        while let next = unfinished.min(by: { $0.key < $1.key })?.value {
            guard await shared.race(next) else {
                diagnostics.increment(Self.endWaitTimedOutKey)
                return false
            }
        }
        return true
    }

    /// The answer of `query`, or nil when `deadline` ends first, by default after `endOfWindowWaitLimit`. The query runs
    /// off the main thread and a later answer is dropped, so a scheduler call that does not answer cannot hold the end
    /// of a window.
    public static func answer<Answer: Sendable>(
        of query: @escaping @Sendable () async -> Answer,
        deadline: @escaping @Sendable () async -> Void = BackgroundTaskRequestSubmitter.defaultDeadline
    ) async -> Answer? {
        await withCheckedContinuation { continuation in
            let first = FirstResult<Answer?>(continuation)
            let timer = Task.detached {
                await deadline()
                first.resume(nil)
            }
            Task.detached {
                first.resume(await query())
                timer.cancel()
            }
        }
    }

    /// Removes the pending request. A request that is still on its way is removed again when it lands, unless the task
    /// has been restarted and its current run has sent a request by then; a request that waits behind it is never sent.
    public func cancel() {
        cancelGeneration += 1
        cancelRequest()
    }

    #if DEBUG
        var lastSubmissionForTesting: Task<Void, Never>? { lastSubmission }
    #endif
}

/// One deadline that several waits race against. A wait that starts after the deadline ended loses at once.
private final class Deadline: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    private var waiting: [FirstResult<Bool>] = []
    private var timer: Task<Void, Never>?

    init(_ deadline: @escaping @Sendable () async -> Void) {
        timer = Task { [weak self] in
            await deadline()
            self?.end()
        }
    }

    /// True when `task` ended first, false when the deadline did.
    func race(_ task: Task<Void, Never>) async -> Bool {
        await withCheckedContinuation { continuation in
            let first = FirstResult<Bool>(continuation)
            let alreadyEnded = lock.withLock { () -> Bool in
                if !ended { waiting.append(first) }
                return ended
            }
            if alreadyEnded {
                first.resume(false)
                return
            }
            Task {
                await task.value
                first.resume(true)
            }
        }
    }

    func cancel() {
        let timer = lock.withLock { () -> Task<Void, Never>? in
            defer { self.timer = nil }
            return self.timer
        }
        timer?.cancel()
    }

    private func end() {
        let waiting = lock.withLock { () -> [FirstResult<Bool>] in
            ended = true
            defer { self.waiting = [] }
            return self.waiting
        }
        for first in waiting { first.resume(false) }
    }
}

/// Resumes one continuation with the first of two results; the later result is dropped.
private final class FirstResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        let continuation = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}
