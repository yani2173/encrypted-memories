/// Tells a host which library refresh its upload signals need. A manual upload refreshes at once. A backup upload
/// waits for the interval of the shared coordinator while the pass runs. One change that carries both signals is
/// served by the immediate refresh, and the end of a pass publishes the refresh that the interval held back.
public struct UploadRefreshSignalTracker: Sendable, Equatable {
    public enum Refresh: Sendable, Equatable {
        case manualUpload
        case backupUpload(passIsRunning: Bool)
    }

    public struct Outcome: Sendable, Equatable {
        public let refresh: Refresh?
        public let passEnded: Bool
    }

    private var backupRevision: UInt64?
    private var manualRevision: Int?
    private var passWasRunning: Bool

    public init(backupRevision: UInt64?, manualRevision: Int?, passIsRunning: Bool) {
        self.backupRevision = backupRevision
        self.manualRevision = manualRevision
        passWasRunning = passIsRunning
    }

    public mutating func observe(backupRevision: UInt64?, manualRevision: Int?, passIsRunning: Bool) -> Outcome {
        defer {
            self.backupRevision = backupRevision
            self.manualRevision = manualRevision
            passWasRunning = passIsRunning
        }
        let refresh: Refresh? =
            if manualRevision != self.manualRevision {
                .manualUpload
            } else if backupRevision != self.backupRevision {
                .backupUpload(passIsRunning: passIsRunning)
            } else {
                nil
            }
        return Outcome(refresh: refresh, passEnded: passWasRunning && !passIsRunning)
    }
}
