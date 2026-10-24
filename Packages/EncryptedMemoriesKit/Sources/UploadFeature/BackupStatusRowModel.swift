import Foundation
import Observation
import UploadCore

/// Cross-platform timeful wrapper around the pure `BackupStatusStabilizer`. Native settings views feed it
/// controller changes and render `displayed`; the shared model owns the one deferred wake and never polls.
@MainActor
@Observable
public final class BackupStatusRowModel {
    public private(set) var displayed = BackupStatusPresentation(BackupStatus())
    private var stabilizer = BackupStatusStabilizer()
    private var wakeTask: Task<Void, Never>?

    public init() {}

    public func ingest(_ status: BackupStatus) {
        apply(stabilizer.ingest(BackupStatusPresentation(status), now: Date()))
    }

    public func cancel() {
        wakeTask?.cancel()
        wakeTask = nil
    }

    private func apply(_ decision: BackupStatusStabilizer.Decision) {
        displayed = decision.display
        wakeTask?.cancel()
        guard let wakeAt = decision.wakeAt else {
            wakeTask = nil
            return
        }
        wakeTask = Task { [weak self] in
            let delay = wakeAt.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.apply(self.stabilizer.wake(now: Date()))
        }
    }
}
