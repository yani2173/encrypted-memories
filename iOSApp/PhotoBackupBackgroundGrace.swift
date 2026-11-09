import PhotoLibraryBackupAdapter
import PhotosCore
import UIKit

/// Protects an active foreground pass with the short system grace window if the app backgrounds.
/// It never owns backup state: the shared controller keeps every transition durable.
@MainActor
final class PhotoBackupBackgroundGrace {
    static let shared = PhotoBackupBackgroundGrace()

    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var generation: UUID?
    private let protection: BackgroundBackupRunProtection
    private let beginTask: (@escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    private let endTask: (UIBackgroundTaskIdentifier) -> Void

    init(
        protection: BackgroundBackupRunProtection = .shared,
        beginTask: @escaping (@escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier = {
            UIApplication.shared.beginBackgroundTask(withName: "Photo backup", expirationHandler: $0)
        },
        endTask: @escaping (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) }
    ) {
        self.protection = protection
        self.beginTask = beginTask
        self.endTask = endTask
    }

    /// Acquire the assertion while the pass is foreground-active. Waiting for `scenePhase == .background`
    /// can be too late for the system to grant it.
    func protectActiveRun(controller: PhotoLibraryBackupController) {
        guard identifier == .invalid else { return }
        guard let runID = controller.activeExecutionRunID else { return }
        // A processing window carries this run; the short grace would only hold the app past the window's own end.
        guard !protection.isProtected(owner: controller, runID: runID) else { return }
        let generation = UUID()
        self.generation = generation
        identifier = beginTask {
            [weak self, weak controller] in
            guard let self, self.generation == generation else { return }
            let isProtected = controller.map { self.protection.isProtected(owner: $0, runID: runID) } ?? false
            BackgroundWorkLog.system.notice(
                .photoBackup, "grace.expired",
                [
                    (.init("protected"), .flag(isProtected)),
                    (.init("stopsItsPass"), .flag(controller != nil && !isProtected)),
                ])
            if let controller, !isProtected {
                controller.stopSync(runID: runID)
            }
            self.end(generation: generation)
        }
        // A refused request can still report expiration. Its callback stays current until end() or a new request.
    }

    func end(generation expectedGeneration: UUID? = nil) {
        if let expectedGeneration, generation != expectedGeneration { return }
        guard identifier != .invalid else {
            generation = nil
            return
        }
        endTask(identifier)
        identifier = .invalid
        generation = nil
    }
}
