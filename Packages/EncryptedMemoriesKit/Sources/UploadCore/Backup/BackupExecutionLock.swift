import Foundation

/// Durable execution ownership for backup runs, shared by every platform. A foreground session, an
/// iOS `BGProcessingTask`, a macOS background activity, and a manual user-triggered run all compete
/// for one lock per queue, so they can never drain the same persistent queue at the same time and a
/// crashed/expired owner can be recovered cleanly on the next start.
///
/// This lock does not replace the queue's crash recovery, which runs first on every pass. It
/// determines which owner may run recovery and drain the queue. Losing the lock leaves rows
/// runnable for the next owner.

/// Who holds (or wants) the lock. An open raw-value wrapper so a platform can name a new owner
/// without a schema change; the common owners are provided as statics.
public struct BackupExecutionOwner: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue.isEmpty ? Self.foreground.rawValue : rawValue
    }

    /// A live user-facing session drives the run.
    public static let foreground = BackupExecutionOwner(rawValue: "foreground")
    /// iOS/iPadOS `BGProcessingTask` catch-up window.
    public static let iOSBackgroundTask = BackupExecutionOwner(rawValue: "iosBackgroundTask")
    /// macOS `NSBackgroundActivityScheduler` window.
    public static let macOSBackgroundActivity = BackupExecutionOwner(rawValue: "macosBackgroundActivity")
    /// A generic background window when the platform is not distinguished.
    public static let background = BackupExecutionOwner(rawValue: "background")
    /// An explicit user-triggered "back up now".
    public static let manual = BackupExecutionOwner(rawValue: "manual")
}

/// A recorded lock. `heartbeatAt` is the liveness signal: an owner refreshes it while working, and
/// a lock whose heartbeat is older than the lease is treated as abandoned (crash / OS kill / BG
/// expiration without a clean release).
public struct BackupExecutionLock: Sendable, Equatable {
    public var owner: BackupExecutionOwner
    public var runID: String
    public var acquiredAt: Date
    public var heartbeatAt: Date
    /// Optional coarse phase for UI/debug ("scanning", "uploading"). Never load-bearing for safety.
    public var phase: String?
    /// Optional platform/process hint for debugging ("ios/pid-1234"). Never load-bearing.
    public var processContext: String?

    public init(
        owner: BackupExecutionOwner,
        runID: String,
        acquiredAt: Date,
        heartbeatAt: Date,
        phase: String? = nil,
        processContext: String? = nil
    ) {
        self.owner = owner
        self.runID = runID
        self.acquiredAt = acquiredAt
        self.heartbeatAt = heartbeatAt
        self.phase = phase
        self.processContext = processContext
    }
}

/// Outcome of an acquire attempt.
public enum BackupLockAcquisition: Sendable, Equatable {
    /// The caller now owns the lock (it was free, stale, or already theirs).
    case acquired(BackupExecutionLock)
    /// A different owner holds a live lock; the caller must not start.
    case busy(BackupExecutionLock)
    /// The store could not be read/written - the caller must not start (safety over progress).
    case unavailable

    public var didAcquire: Bool { if case .acquired = self { return true } else { return false } }
}

/// Outcome of a heartbeat.
public enum BackupLockHeartbeat: Sendable, Equatable {
    /// The caller still owns the lock and its heartbeat moved forward.
    case renewed
    /// The lock row is gone or belongs to another run; the caller must stop its pass.
    case lost
    /// The store could not be read or written; ownership is unknown, so the caller tries again later.
    case unavailable
}

/// Persistence seam for backup execution ownership. One store instance may guard several named
/// locks (default `photoBackup`) so folder and photo backups never collide.
public protocol BackupExecutionLockStore: Sendable {
    /// The current lock regardless of liveness, or nil when free.
    func currentLock() -> BackupExecutionLock?
    /// Take the lock when it is free, already ours (`runID`), or stale (heartbeat past the lease).
    /// A live lock held by a different run returns `.busy`.
    func acquire(
        owner: BackupExecutionOwner, runID: String, phase: String?, processContext: String?
    ) -> BackupLockAcquisition
    /// Refresh our lock's heartbeat (and optional phase). `.lost` means another run owns the lock or nobody does.
    @discardableResult
    func heartbeat(runID: String, phase: String?) -> BackupLockHeartbeat
    /// Release the lock iff `runID` still owns it. Returns whether a row was removed.
    @discardableResult
    func release(runID: String) -> Bool
    /// Clear any lock whose heartbeat predates `cutoff`. Returns the reaped locks (empty when none).
    @discardableResult
    func recoverStaleLocks(olderThan cutoff: Date) -> [BackupExecutionLock]
}

public extension BackupExecutionLockStore {
    func acquire(owner: BackupExecutionOwner, runID: String) -> BackupLockAcquisition {
        acquire(owner: owner, runID: runID, phase: nil, processContext: nil)
    }

    @discardableResult
    func heartbeat(runID: String) -> BackupLockHeartbeat {
        heartbeat(runID: runID, phase: nil)
    }
}
