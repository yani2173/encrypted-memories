import BackgroundTasks
import Foundation
import PhotoLibraryBackupAdapter
import PhotosCore
import UIKit
import UploadCore
import os

@MainActor
private final class PhotoBackupProcessingAttempt {
    var didExpire = false
    var runID: String?
}

/// Owns only the iOS execution opportunities for the shared photo-backup controller.
/// Queueing, dedupe, upload, recovery, and checkpoints remain in the controller/Core.
@MainActor
final class PhotoBackupBackgroundCoordinator {
    static let shared = PhotoBackupBackgroundCoordinator()

    static let processingTaskIdentifier = "at.oncloud.encryptedmemories.photo-backup.processing"

    private static let controllerReadyTimeout: Duration = .seconds(30)

    private let scheduler = BGTaskScheduler.shared
    private let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "PhotoBackupBackground")
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

        if !processingRegistered {
            registrationIssue = .registrationFailed
            publishExecutionIssue()
            logger.error("Photo-backup processing-task registration failed")
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
        scheduler.cancel(taskRequestWithIdentifier: Self.processingTaskIdentifier)
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
    @discardableResult
    func scheduleProcessingCatchUp(controller: PhotoLibraryBackupController? = nil) -> Bool {
        guard !schedulingStopped, !BackupLocalDataPurge.isPurgePending() else { return false }
        let request = BGProcessingTaskRequest(identifier: Self.processingTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        if let date = controller?.nextAutomaticAttemptAt, date > Date() {
            request.earliestBeginDate = date
        }
        do {
            try scheduler.submit(request)
            processingIssue = nil
            publishExecutionIssue(to: controller)
            return true
        } catch {
            processingIssue = Self.executionIssue(for: error)
            publishExecutionIssue(to: controller)
            logger.error("Photo-backup processing submission failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func handleProcessingTask(_ task: BGProcessingTask) {
        processingIssue = nil
        publishExecutionIssue()
        // The delivered request is consumed now. Replace it before doing anything that can expire,
        // fail, or wait for account restoration.
        scheduleProcessingCatchUp()

        let completion = PhotoBackupTaskCompletion(task: task)
        let attempt = PhotoBackupProcessingAttempt()
        _ = Task { @MainActor [weak self] in
            guard !attempt.didExpire else {
                completion.finish(success: false)
                return
            }
            guard let self, let controller = await self.waitForController() else {
                completion.finish(success: false)
                return
            }
            guard !attempt.didExpire else {
                completion.finish(success: false)
                return
            }
            guard controller.isEnabled else {
                self.backupStopped()
                completion.finish(success: true)
                return
            }
            guard !controller.isUserPaused else {
                self.backupPaused()
                completion.finish(success: true)
                return
            }

            defer { attempt.runID = nil }
            await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { runID in
                attempt.runID = runID
                if attempt.didExpire {
                    controller.stopSync(runID: runID)
                }
            }
            self.scheduleProcessingCatchUp(controller: controller)
            completion.finish(success: !attempt.didExpire && !Task.isCancelled)
        }

        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                attempt.didExpire = true
                let controller = PhotoLibraryBackupSharedRef.shared.controller
                if let runID = attempt.runID {
                    controller?.stopSync(runID: runID)
                }
                _ = self?.scheduleProcessingCatchUp(controller: controller)
            }
        }
    }

    private func waitForController() async -> PhotoLibraryBackupController? {
        let controller = await PhotoLibraryBackupSharedRef.shared.controllerWhenReady(
            timeout: Self.controllerReadyTimeout
        )
        if controller == nil, !Task.isCancelled {
            logger.error("Photo-backup controller was not ready during the background launch window")
        }
        return controller
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

private final class PhotoBackupTaskCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let task: BGTask
    private var didFinish = false

    init(task: BGTask) {
        self.task = task
    }

    func finish(success: Bool) {
        let shouldFinish = lock.withLock {
            guard !didFinish else { return false }
            didFinish = true
            return true
        }
        if shouldFinish { task.setTaskCompleted(success: success) }
    }
}
