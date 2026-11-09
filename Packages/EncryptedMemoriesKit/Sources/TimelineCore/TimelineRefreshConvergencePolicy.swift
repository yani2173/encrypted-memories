import Foundation

/// Stable failure classes used by platform shells to distinguish expected server convergence from real errors.
public enum TimelineRefreshFailureReason: Sendable, Equatable {
    case pendingInventoryVisibility
    case scopeAccessLost
    case superseded
    case cancelled
    /// The load succeeded and published the same content it already showed. Consumers treat this as a success:
    /// the refresh found no change, so the upload-refresh coordinator may skip the next interval tick.
    case unchanged
    case other
}

public enum TimelineRefreshConvergenceDecision: Sendable, Equatable {
    case succeeded
    case retry(after: Duration)
    case notYetVisible
    case cancelled
    case failed
}

/// Pure bounded-retry policy for refreshes triggered by a completed upload.
public struct TimelineRefreshConvergencePolicy: Sendable, Equatable {
    public let schedule: TimelineRefreshRetrySchedule
    /// The time that one automatic upload cycle holds back the start of the next one.
    public let automaticInterval: Duration

    public init(schedule: TimelineRefreshRetrySchedule = .uploadDefault, automaticInterval: Duration = .seconds(60)) {
        self.schedule = schedule
        self.automaticInterval = automaticInterval
    }

    /// The uploads of the automatic backup: a backed-up photo already shows as a local tile, so the refresh that
    /// swaps the tile for the Proton photo may wait this long while a pass runs.
    public static let backupUploads = TimelineRefreshConvergencePolicy(automaticInterval: .seconds(30))

    public func decision(
        after failure: TimelineRefreshFailureReason?,
        attempt: Int
    ) -> TimelineRefreshConvergenceDecision {
        guard let failure else { return .succeeded }
        switch failure {
        case .pendingInventoryVisibility:
            let nextAttempt = attempt + 1
            guard schedule.delays.indices.contains(nextAttempt) else { return .notYetVisible }
            return .retry(after: schedule.delays[nextAttempt])
        case .superseded, .cancelled:
            return .cancelled
        case .unchanged:
            return .succeeded
        case .scopeAccessLost, .other:
            return .failed
        }
    }
}
