import Foundation

/// Bridges one callback-driven PhotoKit resource request into Swift concurrency without allowing
/// a missing completion callback to retain the shared heavy-work permit forever.
///
/// Data callbacks run under the same lock as terminal resolution. A timeout therefore waits for an
/// in-progress chunk to finish, cancels the native request, and only then resumes the continuation;
/// cleanup can never race a late writer or SHA accumulator update. Progress or received bytes reset
/// the monotonic inactivity deadline, so large resources may run indefinitely while making progress.
final class PhotoKitResourceRequestLivenessGuard<RequestID: Sendable>: @unchecked Sendable {
    static var defaultStallTimeout: TimeInterval { 180 }
    static var defaultPollInterval: TimeInterval { 5 }

    private struct FinishAction {
        let continuation: CheckedContinuation<Void, Error>?
        let result: Result<Void, Error>
        let requestIDToCancel: RequestID?
        let watchdog: Task<Void, Never>?
    }

    private let lock = NSLock()
    private let stallTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let automaticallyStartsWatchdog: Bool
    private let now: @Sendable () -> TimeInterval
    private let timeoutError: @Sendable () -> Error
    private let requestAdmission: @Sendable () throws -> Void
    private let cancelRequest: @Sendable (RequestID) -> Void

    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private var requestID: RequestID?
    private var cancelWhenRegistered = false
    private var lastActivity: TimeInterval
    private var watchdogTask: Task<Void, Never>?

    init(
        stallTimeout: TimeInterval = PhotoKitResourceRequestLivenessGuard.defaultStallTimeout,
        pollInterval: TimeInterval = PhotoKitResourceRequestLivenessGuard.defaultPollInterval,
        automaticallyStartsWatchdog: Bool = true,
        requestAdmission: @Sendable @escaping () throws -> Void = {},
        now: @Sendable @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        timeoutError: @Sendable @escaping () -> Error = {
            URLError(.timedOut)
        },
        cancelRequest: @Sendable @escaping (RequestID) -> Void
    ) {
        self.stallTimeout = max(0.01, stallTimeout)
        self.pollInterval = max(0.01, min(pollInterval, stallTimeout))
        self.automaticallyStartsWatchdog = automaticallyStartsWatchdog
        self.requestAdmission = requestAdmission
        self.now = now
        self.timeoutError = timeoutError
        self.cancelRequest = cancelRequest
        lastActivity = now()
    }

    deinit {
        watchdogTask?.cancel()
    }

    func waitForCompletion(starting request: () -> RequestID) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                guard install(continuation) else { return }
                do {
                    try requestAdmission()
                    register(request())
                } catch {
                    complete(error: error)
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            self.cancel()
        }
    }

    /// Serializes received-data mutation against terminal timeout/cancellation. Once terminal, late
    /// callbacks are ignored and cannot touch a finalized digest or discarded partial file.
    func receiveData(_ operation: () throws -> Void) {
        var action: FinishAction?
        lock.lock()
        if result == nil {
            do {
                try operation()
                lastActivity = now()
            } catch {
                action = finishLocked(.failure(error), cancelUnderlyingRequest: true)
            }
        }
        lock.unlock()
        perform(action)
    }

    func markActivity() {
        lock.withLock {
            guard result == nil else { return }
            lastActivity = now()
        }
    }

    func complete(error: Error?) {
        finish(error.map(Result.failure) ?? .success(()), cancelUnderlyingRequest: false)
    }

    func cancel() {
        finish(.failure(CancellationError()), cancelUnderlyingRequest: true)
    }

    /// Internal deterministic seam: production calls this from the monotonic watchdog; tests drive
    /// it with a manual clock so liveness coverage does not depend on wall-clock sleeps.
    @discardableResult
    func checkForStall() -> Bool {
        let timeoutError = timeoutError()
        let action: FinishAction? = lock.withLock {
            guard result == nil,
                max(0, now() - lastActivity) >= stallTimeout
            else { return nil }
            return finishLocked(.failure(timeoutError), cancelUnderlyingRequest: true)
        }
        perform(action)
        return action != nil
    }

    var hasRegisteredRequest: Bool {
        lock.withLock { requestID != nil }
    }

    private func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        let immediate: Result<Void, Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            lastActivity = now()
            return nil
        }
        if let immediate {
            continuation.resume(with: immediate)
            return false
        }
        startWatchdogIfNeeded()
        return true
    }

    private func register(_ requestID: RequestID) {
        let cancelImmediately: Bool = lock.withLock {
            guard result == nil else { return cancelWhenRegistered }
            self.requestID = requestID
            return false
        }
        if cancelImmediately { cancelRequest(requestID) }
    }

    private func startWatchdogIfNeeded() {
        guard automaticallyStartsWatchdog else { return }
        lock.withLock {
            guard result == nil, watchdogTask == nil else { return }
            watchdogTask = Task.detached(priority: .utility) { [weak self] in
                await self?.watchForStall()
            }
        }
    }

    private func watchForStall() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(pollInterval * 1_000_000_000)
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if checkForStall() { return }
            if lock.withLock({ result != nil }) { return }
        }
    }

    private func finish(
        _ result: Result<Void, Error>,
        cancelUnderlyingRequest: Bool
    ) {
        let action = lock.withLock {
            finishLocked(result, cancelUnderlyingRequest: cancelUnderlyingRequest)
        }
        perform(action)
    }

    private func finishLocked(
        _ result: Result<Void, Error>,
        cancelUnderlyingRequest: Bool
    ) -> FinishAction? {
        guard self.result == nil else { return nil }
        self.result = result
        cancelWhenRegistered = cancelUnderlyingRequest
        let action = FinishAction(
            continuation: continuation,
            result: result,
            requestIDToCancel: cancelUnderlyingRequest ? requestID : nil,
            watchdog: watchdogTask
        )
        continuation = nil
        watchdogTask = nil
        return action
    }

    private func perform(_ action: FinishAction?) {
        guard let action else { return }
        action.watchdog?.cancel()
        if let requestID = action.requestIDToCancel {
            cancelRequest(requestID)
        }
        action.continuation?.resume(with: action.result)
    }
}
