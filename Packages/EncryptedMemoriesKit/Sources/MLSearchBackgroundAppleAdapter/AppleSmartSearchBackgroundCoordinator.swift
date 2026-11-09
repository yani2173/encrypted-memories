import Foundation
import MLSearchCore
import PhotosCore
import os

#if os(iOS)
    import BackgroundTasks
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

/// Apple execution opportunities for the account's existing indexer. No second session, index,
/// download queue or credential store is created by a background launch.
@MainActor
public final class AppleSmartSearchBackgroundCoordinator {
    public static let shared = AppleSmartSearchBackgroundCoordinator()
    nonisolated public static let processingTaskIdentifier = "at.oncloud.encryptedmemories.smart-search.processing"

    private let reference = WeakAsyncReference<MLSmartSearchLifecycle>()
    private let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "SmartSearchBackground")
    private var observationTask: Task<Void, Never>?
    private var isEnabled = false
    private var schedulingStopped = false

    #if os(iOS)
        private var didRegister = false
        private var isForeground = UIApplication.shared.applicationState != .background
        private var windows: Set<UUID> = []
        private var processing: [UUID: Task<Void, Never>] = [:]
        private var transitionTask: Task<Void, Never>?
        private lazy var submitter = BackgroundTaskRequestSubmitter(
            cancelRequest: {
                BGTaskScheduler.shared.cancel(
                    taskRequestWithIdentifier: AppleSmartSearchBackgroundCoordinator.processingTaskIdentifier)
            },
            onErrorAfterCancel: { [logger] error in
                logger.error(
                    "Smart Search background submission failed after a cancel: \(error.localizedDescription, privacy: .public)"
                )
            })
    #elseif os(macOS)
        private var activityScheduler: NSBackgroundActivityScheduler?
        private var activityGeneration = UUID()
    #endif

    private init() {}

    /// Must be called from app initialization, before the system delivers launch tasks.
    public func register() {
        #if os(iOS)
            guard !didRegister else { return }
            didRegister = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: Self.processingTaskIdentifier, using: nil
            ) { task in
                guard let task = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                Task { @MainActor in Self.shared.handle(task) }
            }
            if !didRegister { logger.error("Smart Search background registration failed") }
        #endif
    }

    public func configure(lifecycle: MLSmartSearchLifecycle) {
        if let previous = reference.value, previous !== lifecycle { detach(lifecycle: previous) }
        schedulingStopped = false
        reference.value = lifecycle
        observationTask?.cancel()
        observationTask = Task { [weak self, weak lifecycle] in
            guard let lifecycle else { return }
            let snapshots = await lifecycle.snapshots()
            for await snapshot in snapshots {
                guard !Task.isCancelled, let self, self.reference.value === lifecycle else { return }
                if self.isEnabled != snapshot.isEnabled {
                    self.isEnabled = snapshot.isEnabled
                    if snapshot.isEnabled { self.schedule() } else { self.cancelScheduling() }
                }
            }
        }
        #if os(iOS)
            isForeground = UIApplication.shared.applicationState != .background
            _ = reconcileExecution()
        #endif
    }

    public func detach(lifecycle: MLSmartSearchLifecycle) {
        guard reference.value === lifecycle else { return }
        stop()
    }

    /// Also valid before account restoration: a pending local reset must revoke queued OS work.
    public func stop() {
        schedulingStopped = true
        reference.value = nil
        observationTask?.cancel()
        observationTask = nil
        isEnabled = false
        cancelScheduling()
        #if os(iOS)
            for task in processing.values { task.cancel() }
            windows.removeAll()
        #endif
    }

    public func applicationStateChanged(isForeground: Bool) {
        #if os(iOS)
            self.isForeground = isForeground
            if isForeground {
                _ = reconcileExecution()
            } else {
                if isEnabled { schedule() }
                // A finite UIKit grace period lets the current quantum drain when there is no
                // BGProcessing window. It is not permission to start another indexing pass.
                let grace = IndexingDrainGrace()
                grace.begin()
                let transition = reconcileExecution()
                Task {
                    await transition.value
                    grace.end()
                }
            }
        #endif
    }

    private func cancelScheduling() {
        #if os(iOS)
            submitter.cancel()
        #elseif os(macOS)
            activityScheduler?.invalidate()
            activityScheduler = nil
            activityGeneration = UUID()
        #endif
    }

    private func schedule() {
        guard !schedulingStopped else { return }
        #if os(iOS)
            // The date counts from this call, not from the moment the request reaches the scheduler.
            let earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            submitter.submit(
                blocking: {
                    try BGTaskScheduler.shared.submit(Self.processingRequest(earliestBeginDate: earliestBeginDate))
                },
                offMainThread: Self.offMainSubmission(earliestBeginDate: earliestBeginDate),
                completion: { [logger] error in
                    BackgroundWorkLog.system.requestSubmitted(
                        .smartSearch, earliestBegin: earliestBeginDate, errorCode: error.map { ($0 as NSError).code })
                    guard let error else { return }
                    logger.error(
                        "Smart Search background submission failed: \(error.localizedDescription, privacy: .public)")
                })
        #elseif os(macOS)
            guard activityScheduler == nil else { return }
            let scheduler = NSBackgroundActivityScheduler(identifier: Self.processingTaskIdentifier)
            scheduler.interval = 15 * 60
            scheduler.tolerance = 5 * 60
            scheduler.repeats = true
            scheduler.qualityOfService = .background
            let generation = UUID()
            activityGeneration = generation
            scheduler.schedule { completion in
                Task { @MainActor in
                    guard Self.shared.activityGeneration == generation else {
                        completion(.finished)
                        return
                    }
                    guard let scheduler = Self.shared.activityScheduler, !scheduler.shouldDefer else {
                        completion(.deferred)
                        return
                    }
                    guard let lifecycle = Self.shared.reference.value else {
                        completion(.finished)
                        return
                    }
                    let activity = ProcessInfo.processInfo.beginActivity(
                        options: .background, reason: "Smart Search indexing")
                    _ = await lifecycle.performBackgroundCatchUp()
                    ProcessInfo.processInfo.endActivity(activity)
                    completion(.finished)
                }
            }
            activityScheduler = scheduler
        #endif
    }

    #if os(iOS)
        nonisolated static func processingRequest(earliestBeginDate: Date) -> BGProcessingTaskRequest {
            let request = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
            request.requiresExternalPower = true
            request.requiresNetworkConnectivity = false
            request.earliestBeginDate = earliestBeginDate
            return request
        }

        /// The iOS 27 call, which must not run on the main thread; nil before iOS 27.
        nonisolated static func offMainSubmission(earliestBeginDate: Date) -> (@Sendable () async throws -> Void)? {
            guard #available(iOS 27.0, *) else { return nil }
            return {
                try await BGTaskScheduler.shared.submitTaskRequest(
                    processingRequest(earliestBeginDate: earliestBeginDate))
            }
        }

        /// The end once the wait for the requests returned. The ledger records an expiry that came during the wait; the
        /// success stays the one read at the end of the work, so a finished pass is not reported as failed only because
        /// the window expired while it waited for the scheduler.
        nonisolated static func windowEndAfterWait(
            _ workEnd: (outcome: BackgroundWindowOutcome, reportsSuccess: Bool), didExpire: Bool
        ) -> (outcome: BackgroundWindowOutcome, reportsSuccess: Bool?) {
            (workEnd.outcome.afterTheEndWait(didExpire: didExpire), workEnd.reportsSuccess)
        }

        /// Reads the cancel first, then the expiry. The expiration handler marks the expiry before it cancels, so a cancel
        /// that the read sees always comes with a seen expiry when the expiry caused it.
        nonisolated static func endSnapshot(
            isCancelled: () -> Bool, didExpire: () -> Bool
        ) -> (didExpire: Bool, wasCancelled: Bool) {
            let wasCancelled = isCancelled()
            return (didExpire(), wasCancelled)
        }

        /// How a Smart Search window ends: its outcome, and the success that the OS hears. `result` is nil when no
        /// catch-up ran: such a window failed, unless it expired. That includes a window that arrives after `stop()`.
        /// The success is the one the OS heard before windows were recorded: false without a catch-up, else true
        /// exactly when the catch-up was neither cancelled nor stopped, even when the window expired meanwhile.
        nonisolated static func windowEnd(
            result: MLBackgroundProcessingResult?, didExpire: Bool, wasCancelled: Bool
        ) -> (outcome: BackgroundWindowOutcome, reportsSuccess: Bool) {
            guard let result else { return (didExpire ? .expired : .failed, false) }
            let completed = !wasCancelled && result != .cancelled
            let outcome = BackgroundWindowOutcome.afterWork(didExpire: didExpire, didComplete: completed)
            // A deferred pass could not index now. The OS hears success, as before.
            return (outcome == .ran && result == .deferred ? .notNeeded : outcome, completed)
        }

        /// Serialize lifecycle transitions. Each queued transition reads the latest opportunity,
        /// so an expired background task cannot disable a newly foregrounded app.
        private func reconcileExecution() -> Task<Void, Never> {
            let previous = transitionTask
            let lifecycle = reference.value
            let task = Task { [weak self] in
                await previous?.value
                guard let self, let lifecycle, self.reference.value === lifecycle else { return }
                await lifecycle.setIndexingExecutionAllowed(self.isForeground || !self.windows.isEmpty)
            }
            transitionTask = task
            return task
        }

        private func handle(_ task: BGProcessingTask) {
            let completion = BackgroundWindowCompletion(kind: .smartSearch) { task.setTaskCompleted(success: $0) }
            // Every end waits, bounded, until the requests of this window reached the scheduler: before iOS 27 they went
            // out at once.
            let pendingRequests: @Sendable () async -> Void = { [submitter] in
                await submitter.pendingSubmissionsEnded()
            }
            guard !schedulingStopped else {
                let end = Self.windowEnd(result: nil, didExpire: false, wasCancelled: false)
                Task {
                    await completion.finish(end.outcome, reportsSuccess: end.reportsSuccess, after: pendingRequests)
                }
                return
            }
            // One read of the cancel and the expiry at the end of the work gives the outcome and the success. After
            // the wait, only the recorded outcome takes a later expiry into account.
            func finish(_ result: MLBackgroundProcessingResult?) async {
                let snapshot = Self.endSnapshot(isCancelled: { Task.isCancelled }, didExpire: { completion.didExpire })
                let workEnd = Self.windowEnd(
                    result: result, didExpire: snapshot.didExpire, wasCancelled: snapshot.wasCancelled)
                await completion.finish(after: pendingRequests) {
                    Self.windowEndAfterWait(workEnd, didExpire: completion.didExpire)
                }
            }
            // A cold, locked launch may not restore when-unlocked credentials. Preserve the
            // security policy and retry later; never start a second login/session bootstrap.
            schedule()
            let id = UUID()
            let operation = Task { [weak self] in
                defer { task.expirationHandler = nil }
                guard let self else {
                    await finish(nil)
                    return
                }
                // A launch without a scene has not started the account yet; an operation that the window's end
                // cancelled before it ran starts nothing and ends below.
                let waitStart = ContinuousClock.now
                BackgroundLaunchAccountStart.shared.ensureStarted(unlessCancelled: Task.isCancelled)
                let wait = await BackgroundAccountReadiness.shared.wait(for: self.reference, timeout: .seconds(30))
                BackgroundWorkLog.system.accountWait(.smartSearch, wait, waited: .now - waitStart)
                if case .cannotRun = wait {
                    // The reads of the saved sign-in show that no account can come in this window.
                    self.processing.removeValue(forKey: id)
                    await completion.finish(
                        wait.outcomeWithoutService(didExpire: completion.didExpire), after: pendingRequests)
                    return
                }
                guard case .ready(let lifecycle) = wait, !Task.isCancelled, self.reference.value === lifecycle else {
                    self.processing.removeValue(forKey: id)
                    await finish(nil)
                    return
                }
                self.windows.insert(id)
                await self.reconcileExecution().value
                // The reference can be published before the UI's startup task runs. Restore
                // this same idempotent lifecycle before interpreting its default disabled state.
                await lifecycle.start()
                let result = await lifecycle.performBackgroundCatchUp()
                self.windows.remove(id)
                await self.reconcileExecution().value
                if !self.isForeground { await lifecycle.releaseMemory() }
                self.processing.removeValue(forKey: id)
                await finish(result)
            }
            processing[id] = operation
            task.expirationHandler = {
                BackgroundWorkLog.system.expirationReceived(.smartSearch)
                completion.markExpired()
                operation.cancel()
            }
        }
    #endif
}

extension AppleSmartSearchBackgroundCoordinator: MLSmartSearchBackgroundHost {}

#if os(iOS)
    @MainActor
    private final class IndexingDrainGrace {
        private var identifier = UIBackgroundTaskIdentifier.invalid

        func begin() {
            identifier = UIApplication.shared.beginBackgroundTask(withName: "SmartSearchDrain") { [weak self] in
                self?.end()
            }
        }

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
#endif
