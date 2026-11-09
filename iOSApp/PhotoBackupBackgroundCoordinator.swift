import BackgroundTasks
import Foundation
import PhotoLibraryBackupAdapter
import PhotosCore
import UIKit
import UploadCore
import os

@MainActor
final class PhotoBackupProcessingAttempt {
    var didExpire = false
    var runID: String?
    /// The work of this window. Expiration cancels it, so a pass that still waits for the first network path ends.
    var work: Task<Void, Never>?
    private let protection: BackgroundBackupRunProtection
    private let endShortGrace: @MainActor () -> Void
    private weak var controller: PhotoLibraryBackupController?
    private var protectionToken: UUID?
    private var protectedRunID: String?
    #if DEBUG
        var beforeRunAdmissionForTesting: ((String) -> Void)?
        private(set) var cancellationReleaseEndedForTesting = false
    #endif

    init(
        protection: BackgroundBackupRunProtection = .shared,
        endShortGrace: @escaping @MainActor () -> Void = { PhotoBackupBackgroundGrace.shared.end() }
    ) {
        self.protection = protection
        self.endShortGrace = endShortGrace
    }

    func run(controller: PhotoLibraryBackupController) async -> BackgroundCatchUpEnd {
        guard !didExpire, !Task.isCancelled else { return .done }
        self.controller = controller
        defer {
            releaseProtection()
            runID = nil
            self.controller = nil
        }
        return await withTaskCancellationHandler {
            await controller.backgroundCatchUp(
                owner: .iOSBackgroundTask,
                onRunStarted: { runID in
                    self.runID = runID
                    #if DEBUG
                        self.beforeRunAdmissionForTesting?(runID)
                    #endif
                    if self.didExpire || Task.isCancelled {
                        self.releaseProtection()
                        if !self.protection.isProtected(owner: controller, runID: runID) {
                            controller.stopBackgroundWindowRun(runID: runID)
                        }
                    } else {
                        self.holdProtection(controller: controller, runID: runID)
                    }
                },
                onRunAdmitted: { runID in
                    // The run starts for this window, and a waiting window resumes only later: the short grace can
                    // expire before that, so the protection begins now. `onRunStarted` decides whether the run stays.
                    guard !self.didExpire else { return }
                    self.holdProtection(controller: controller, runID: runID)
                })
        } onCancel: {
            Task { @MainActor in
                self.releaseProtection()
                #if DEBUG
                    self.cancellationReleaseEndedForTesting = true
                #endif
            }
        }
    }

    func expire() {
        didExpire = true
        releaseProtection()
        work?.cancel()
        if let controller, let runID, !protection.isProtected(owner: controller, runID: runID) {
            controller.stopBackgroundWindowRun(runID: runID)
        }
    }

    /// Refresh scans record their run for cancellation, but never protect an upload pass from the short grace.
    func noteRefreshRun(controller: PhotoLibraryBackupController?, runID: String) {
        self.runID = runID
        if didExpire { controller?.stopBackgroundWindowRun(runID: runID) }
    }

    private func holdProtection(controller: PhotoLibraryBackupController, runID: String) {
        guard protectedRunID != runID else { return }
        // After the pass it took over, a window can run a pass of its own for the person's retry; it protects that run.
        releaseProtection()
        protectionToken = protection.hold(owner: controller, runID: runID)
        protectedRunID = runID
        // The window carries the run from now on; a short grace that a pass began before would only warn and hold.
        endShortGrace()
    }

    private func releaseProtection() {
        if let protectionToken { protection.release(protectionToken) }
        protectionToken = nil
        protectedRunID = nil
    }
}

/// Owns only the iOS execution opportunities for the shared photo-backup controller.
/// Queueing, dedupe, upload, recovery, and checkpoints remain in the controller/Core.
@MainActor
final class PhotoBackupBackgroundCoordinator {
    static let shared = PhotoBackupBackgroundCoordinator()

    nonisolated static let processingTaskIdentifier = "at.oncloud.encryptedmemories.photo-backup.processing"
    /// The short app refresh task, which only scans the photo library (PhotoLibraryRefreshWindow).
    nonisolated static let refreshTaskIdentifier = "at.oncloud.encryptedmemories.photo-backup.refresh"

    private static let controllerReadyTimeout: Duration = .seconds(30)

    private let scheduler = BGTaskScheduler.shared
    private let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "PhotoBackupBackground")
    private lazy var submitter = BackgroundTaskRequestSubmitter(
        cancelRequest: {
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: PhotoBackupBackgroundCoordinator.processingTaskIdentifier)
        },
        onErrorAfterCancel: { [logger] error in
            logger.error(
                "Photo-backup submission failed after a cancel: \(error.localizedDescription, privacy: .public)")
        })
    private lazy var refreshSubmitter = BackgroundTaskRequestSubmitter(
        cancelRequest: {
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: PhotoBackupBackgroundCoordinator.refreshTaskIdentifier)
        },
        onErrorAfterCancel: { [logger] error in
            logger.error(
                "Library-refresh submission failed after a cancel: \(error.localizedDescription, privacy: .public)")
        })
    /// The check of the pending processing request, which a refresh window runs before it submits one.
    private lazy var processingRequestCheck = PhotoBackupProcessingRequestCheck(
        pendingIdentifiers: { await BGTaskScheduler.shared.pendingTaskRequests().map(\.identifier) },
        submit: { [weak self] in
            self?.scheduleProcessingCatchUp(controller: PhotoLibraryBackupSharedRef.shared.controller)
        })
    private var didRegister = false
    private var registrationIssue: BackupExecutionOpportunityIssue?
    private var processingIssue: BackupExecutionOpportunityIssue?
    private var applicationIsForegroundActive = false
    private var backupIsActivelyProcessing = false
    private var schedulingStopped = false

    private init() {}

    /// Registration happens during app initialization, before a background launch can be delivered.
    func register() {
        guard !didRegister else { return }
        didRegister = true

        let processingRegistered = scheduler.register(
            forTaskWithIdentifier: Self.processingTaskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                Self.shared.handleProcessingTask(processingTask)
            }
        }

        let refreshRegistered = scheduler.register(
            forTaskWithIdentifier: Self.refreshTaskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                Self.shared.handleRefreshTask(refreshTask)
            }
        }

        if !processingRegistered || !refreshRegistered {
            registrationIssue = .registrationFailed
            publishExecutionIssue()
            logger.error(
                "Background task registration failed: processing \(processingRegistered), refresh \(refreshRegistered)"
            )
        }
    }

    /// Connects the account-scoped shared controller to the platform runtime. No backup behavior
    /// is implemented here; the hooks only protect an already-running shared pass from suspension.
    func configure(controller: PhotoLibraryBackupController) {
        schedulingStopped = false
        PhotoLibraryBackupSharedRef.shared.controller = controller
        publishExecutionIssue(to: controller)
        applicationIsForegroundActive = UIApplication.shared.applicationState == .active
        controller.idleTimerHook = { [weak controller] isBackingUp in
            Self.shared.backupIsActivelyProcessing = isBackingUp
            Self.shared.updateIdleTimer()
            guard let controller else {
                PhotoBackupBackgroundGrace.shared.end()
                return
            }
            if isBackingUp {
                PhotoBackupBackgroundGrace.shared.protectActiveRun(controller: controller)
            } else {
                PhotoBackupBackgroundGrace.shared.end()
            }
        }
        if controller.isEnabled, !controller.isUserPaused {
            scheduleProcessingCatchUp(controller: controller)
        }
    }

    func applicationDidEnterBackground(controller: PhotoLibraryBackupController?) {
        applicationIsForegroundActive = false
        updateIdleTimer()
        guard let controller, controller.isEnabled, !controller.isUserPaused else { return }
        scheduleProcessingCatchUp(controller: controller)
    }

    /// Foreground execution no longer depends on a queued background opportunity. Clear transient
    /// scheduler issues immediately so a failed discretionary submission cannot flash as a failed
    /// backup while the shared controller is visibly running.
    func applicationDidBecomeActive(controller: PhotoLibraryBackupController?) {
        applicationIsForegroundActive = true
        updateIdleTimer()
        processingIssue = nil
        publishExecutionIssue(to: controller)
        controller?.applicationDidBecomeActive()
    }

    func backupPaused() {
        stopScheduling(detachController: false)
    }

    func backupResumed(controller: PhotoLibraryBackupController) {
        schedulingStopped = false
        PhotoLibraryBackupSharedRef.shared.controller = controller
        if controller.isEnabled, !controller.isUserPaused {
            scheduleProcessingCatchUp(controller: controller)
        }
    }

    func backupStopped() {
        stopScheduling(detachController: true)
    }

    /// Turns backup on from the settings screen. A stop cancelled the background request and detached the
    /// controller; turning backup on again re-arms both, or backup would run only in the foreground until the
    /// next launch.
    func enableBackup(controller: PhotoLibraryBackupController) async {
        await controller.enableBackup()
        backupResumed(controller: controller)
    }

    var isSchedulingStopped: Bool { schedulingStopped }

    private func stopScheduling(detachController: Bool) {
        schedulingStopped = true
        submitter.cancel()
        refreshSubmitter.cancel()
        processingIssue = nil
        publishExecutionIssue()
        PhotoBackupBackgroundGrace.shared.end()
        if detachController {
            PhotoLibraryBackupSharedRef.shared.controller = nil
        }
        backupIsActivelyProcessing = false
        updateIdleTimer()
    }

    func displayPreferenceDidChange() {
        updateIdleTimer()
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = BackupDisplayWakePolicy.shouldKeepDisplayAwake(
            userOptedIn: UserDefaults.standard.bool(
                forKey: AppSettingsKey.keepDisplayAwakeDuringForegroundBackup
            ),
            applicationIsForegroundActive: applicationIsForegroundActive,
            backupIsActivelyProcessing: backupIsActivelyProcessing
        )
    }

    /// Keeps one future catch-up request pending. Submission replaces an existing request with the
    /// same identifier; errors are logged rather than silently turning background backup into a no-op.
    func scheduleProcessingCatchUp(controller: PhotoLibraryBackupController? = nil) {
        guard !schedulingStopped, !BackupLocalDataPurge.isPurgePending() else { return }
        var earliestBeginDate: Date?
        if let date = controller?.nextAutomaticAttemptAt, date > Date() {
            earliestBeginDate = date
        }
        submitter.submit(
            blocking: { try scheduler.submit(Self.processingRequest(earliestBeginDate: earliestBeginDate)) },
            offMainThread: Self.offMainSubmission(earliestBeginDate: earliestBeginDate),
            completion: { [weak self] error in
                BackgroundWorkLog.system.requestSubmitted(
                    .photoBackup, earliestBegin: earliestBeginDate, errorCode: error.map { ($0 as NSError).code })
                guard let self else { return }
                guard let error else {
                    self.processingIssue = nil
                    self.publishExecutionIssue(to: controller)
                    return
                }
                self.processingIssue = Self.executionIssue(for: error)
                self.publishExecutionIssue(to: controller)
                self.logger.error(
                    "Photo-backup processing submission failed: \(error.localizedDescription, privacy: .public)")
            })
        scheduleLibraryRefresh()
    }

    /// Keeps one refresh request pending, `PhotoLibraryRefreshWindow.nextRequestDelay` after it is planned; a new
    /// submission replaces the pending one. Its errors are logged; the processing request reports the scheduler's state.
    func scheduleLibraryRefresh() {
        guard !schedulingStopped, !BackupLocalDataPurge.isPurgePending() else { return }
        let earliestBeginDate = Date().addingTimeInterval(PhotoLibraryRefreshWindow.nextRequestDelay)
        refreshSubmitter.submit(
            blocking: { try scheduler.submit(Self.refreshRequest(earliestBeginDate: earliestBeginDate)) },
            offMainThread: Self.offMainRefreshSubmission(earliestBeginDate: earliestBeginDate),
            completion: { [weak self] error in
                BackgroundWorkLog.system.requestSubmitted(
                    .libraryRefresh, earliestBegin: earliestBeginDate, errorCode: error.map { ($0 as NSError).code })
                guard let error else { return }
                self?.logger.error(
                    "Library-refresh submission failed: \(error.localizedDescription, privacy: .public)")
            })
    }

    nonisolated static func refreshRequest(earliestBeginDate: Date) -> BGAppRefreshTaskRequest {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = earliestBeginDate
        return request
    }

    /// The iOS 27 call for the refresh request, which must not run on the main thread; nil before iOS 27.
    nonisolated static func offMainRefreshSubmission(earliestBeginDate: Date) -> (@Sendable () async throws -> Void)? {
        guard #available(iOS 27.0, *) else { return nil }
        return {
            try await BGTaskScheduler.shared.submitTaskRequest(refreshRequest(earliestBeginDate: earliestBeginDate))
        }
    }

    nonisolated static func processingRequest(earliestBeginDate: Date?) -> BGProcessingTaskRequest {
        let request = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = earliestBeginDate
        return request
    }

    /// The iOS 27 call, which must not run on the main thread; nil before iOS 27.
    nonisolated static func offMainSubmission(earliestBeginDate: Date?) -> (@Sendable () async throws -> Void)? {
        guard #available(iOS 27.0, *) else { return nil }
        return {
            try await BGTaskScheduler.shared.submitTaskRequest(processingRequest(earliestBeginDate: earliestBeginDate))
        }
    }

    private func handleProcessingTask(_ task: BGProcessingTask) {
        processingIssue = nil
        publishExecutionIssue()
        // The delivered request is consumed now. Replace it before doing anything that can expire,
        // fail, or wait for account restoration.
        scheduleProcessingCatchUp()

        let completion = BackgroundWindowCompletion(kind: .photoBackup) { task.setTaskCompleted(success: $0) }
        // Every end waits, bounded, until the window's requests reached the scheduler: before iOS 27 the request went
        // out at once, before the window ended.
        let pendingRequests: @Sendable () async -> Void = { [submitter] in await submitter.pendingSubmissionsEnded() }
        let attempt = PhotoBackupProcessingAttempt()
        attempt.work = Task { @MainActor [weak self] in
            guard !attempt.didExpire else {
                await completion.finish(.expired, after: pendingRequests)
                return
            }
            // A launch without a scene has not started the account yet.
            let waitStart = ContinuousClock.now
            BackgroundLaunchAccountStart.shared.ensureStarted()
            let wait = await self?.waitForController() ?? .notReady
            BackgroundWorkLog.system.accountWait(.photoBackup, wait, waited: .now - waitStart)
            guard let self, case .ready(let controller) = wait else {
                let outcome = wait.outcomeWithoutService(didExpire: attempt.didExpire)
                await completion.finish(outcome, after: pendingRequests)
                return
            }
            guard !attempt.didExpire else {
                await completion.finish(.expired, after: pendingRequests)
                return
            }
            guard controller.isEnabled else {
                self.backupStopped()
                await completion.finish(.notNeeded, after: pendingRequests)
                return
            }
            guard !controller.isUserPaused else {
                self.backupPaused()
                await completion.finish(.notNeeded, after: pendingRequests)
                return
            }

            let catchUp = await attempt.run(controller: controller)
            self.scheduleProcessingCatchUp(controller: controller)
            let waitedForNetwork = catchUp == .noNetworkPath
            // The state is read when the window ends, after the wait, as before the wait existed.
            await completion.finish(after: pendingRequests) {
                let outcome = BackgroundWindowOutcome.afterWork(
                    didExpire: attempt.didExpire, didComplete: !Task.isCancelled, waitedForNetwork: waitedForNetwork)
                return (outcome, nil)
            }
        }

        // The window's work submits the next request when it returns, after an expiry too, and the window's start
        // submitted one already.
        task.expirationHandler = {
            BackgroundWorkLog.system.expirationReceived(.photoBackup)
            Task { @MainActor in
                attempt.expire()
            }
        }
    }

    /// A refresh window scans the photo library and uploads nothing (PhotoLibraryRefreshWindow).
    private func handleRefreshTask(_ task: BGAppRefreshTask) {
        let completion = PhotoLibraryRefreshWindow.begin { task.setTaskCompleted(success: $0) }
        // The window can also submit the processing request (ensureLongWindowRequest), so its end waits for both.
        let pendingRequests: @Sendable () async -> Void = { [refreshSubmitter, submitter] in
            async let refresh = refreshSubmitter.pendingSubmissionsEnded()
            async let processing = submitter.pendingSubmissionsEnded()
            _ = await (refresh, processing)
        }
        let attempt = PhotoBackupProcessingAttempt()
        attempt.work = Task { @MainActor [weak self] in
            let outcome = await PhotoLibraryRefreshWindow.run(
                scheduleNext: { self?.scheduleLibraryRefresh() },
                isLowPowerModeOn: { ProcessInfo.processInfo.isLowPowerModeEnabled },
                startAccount: { BackgroundLaunchAccountStart.shared.ensureStarted() },
                waitForController: { await PhotoLibraryBackupSharedRef.shared.controllerWhenReady(timeout: $0) },
                didExpire: { attempt.didExpire },
                backupStopped: { self?.backupStopped() },
                backupPaused: { self?.backupPaused() },
                ensureLongWindowRequest: { await self?.ensureProcessingRequest() },
                onRunStarted: { runID in
                    attempt.noteRefreshRun(controller: PhotoLibraryBackupSharedRef.shared.controller, runID: runID)
                })
            attempt.runID = nil
            await completion.finish(after: pendingRequests) {
                (outcome.afterTheEndWait(didExpire: attempt.didExpire), nil)
            }
        }
        task.expirationHandler = {
            BackgroundWorkLog.system.expirationReceived(.libraryRefresh)
            Task { @MainActor in
                attempt.didExpire = true
                attempt.work?.cancel()
                if let runID = attempt.runID {
                    PhotoLibraryBackupSharedRef.shared.controller?.stopBackgroundWindowRun(runID: runID)
                }
            }
        }
    }

    /// Submits the processing request only when none is pending, so a short window never moves the next long one.
    /// The wait and the fallback for a scheduler that does not answer live in `PhotoBackupProcessingRequestCheck`.
    private func ensureProcessingRequest() async {
        await processingRequestCheck.run()
    }

    private func waitForController() async -> BackgroundAccountWait<PhotoLibraryBackupController> {
        let wait = await PhotoLibraryBackupSharedRef.shared.controllerWhenReady(timeout: Self.controllerReadyTimeout)
        if case .notReady = wait, !Task.isCancelled {
            logger.error("Photo-backup controller was not ready during the background launch window")
        }
        return wait
    }

    private func publishExecutionIssue(to controller: PhotoLibraryBackupController? = nil) {
        let issue = registrationIssue ?? processingIssue
        (controller ?? PhotoLibraryBackupSharedRef.shared.controller)?.setExecutionOpportunityIssue(issue)
    }

    private static func executionIssue(for error: Error) -> BackupExecutionOpportunityIssue {
        let error = error as NSError
        guard error.domain == BGTaskScheduler.errorDomain,
            let code = BGTaskScheduler.Error.Code(rawValue: error.code)
        else { return .unknown }
        switch code {
        case .unavailable: return .backgroundRefreshUnavailable
        case .notPermitted: return .backgroundLaunchNotPermitted
        case .tooManyPendingTaskRequests: return .schedulerCapacity
        case .immediateRunIneligible: return .immediateRunIneligible
        @unknown default: return .unknown
        }
    }
}
