import UIKit
import UploadCore

/// Lets the running batch of a merge finish when the app goes to the background, with the short system grace window.
/// Merge All starts no further batch until the app is active again, then it continues. The shared
/// `ExactDuplicatesModel` owns the merge; this adapter only holds the app awake.
@MainActor
final class DuplicatesMergeBackgroundGrace {
    static let shared = DuplicatesMergeBackgroundGrace()

    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var generation: UUID?

    /// The app went to the background: pauses the merge of `model` and holds the app awake until its running batch
    /// finished.
    func applicationDidEnterBackground(model: ExactDuplicatesModel?) {
        // A pause that already holds the app ends the hold itself.
        guard let model, model.isMerging, generation == nil else { return }
        let generation = UUID()
        self.generation = generation
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Merge duplicates") { [weak self] in
            self?.end(generation: generation)
        }
        // The pause applies now, so a return to the app before the task below runs still continues the merge.
        // Without the grace window, the merge still pauses and continues when the app is active again.
        model.pauseMerging()
        Task { [weak self] in
            await model.runningMergeWorkEnded()
            self?.end(generation: generation)
        }
    }

    /// The app is active again: the merge continues.
    func applicationDidBecomeActive(model: ExactDuplicatesModel?) {
        end()
        model?.resumeMerging()
    }

    private func end(generation expectedGeneration: UUID? = nil) {
        if let expectedGeneration, generation != expectedGeneration { return }
        generation = nil
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
