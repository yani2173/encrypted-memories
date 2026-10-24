import Foundation

/// Smooths the runner's monotonic sent-bytes counter into one calm bytes-per-second value for the backup status.
///
/// The caller supplies every timestamp, so tests control time. The rate between two movements of the counter is
/// folded into an exponential moving average with `timeConstant`. The speed stays hidden until
/// `warmUp` seconds of movement are known, and it disappears when the counter has not moved for longer than the
/// gap tolerance. A shorter pause keeps the last value instead of dragging it down. Changes of the shown value
/// are at most `displayInterval` apart. `reset()` forgets everything, so a resume starts fresh.
public struct BackupUploadSpeedEstimator: Sendable, Equatable {
    /// Weight of older movement in the average: the average forgets a rate after about this many seconds.
    public static let timeConstant: TimeInterval = 15
    /// Seconds of known movement before a first speed is shown.
    public static let warmUp: TimeInterval = 3
    /// A pause of at most this many seconds keeps the last speed; coarse counter steps can raise the tolerance.
    public static let minimumGapTolerance: TimeInterval = 8
    /// No pause is tolerated beyond this, however coarse the counter steps are. It also bounds the first step of a run.
    public static let maximumGapTolerance: TimeInterval = 120
    /// The shown speed changes at most this often.
    public static let displayInterval: TimeInterval = 1

    private var lastBytes: Int64?
    private var lastMovement: Date?
    private var lastMovementInterval: TimeInterval = 0
    private var runStart: Date?
    private var smoothed: Double?
    private var shown: Shown?

    private struct Shown: Sendable, Equatable {
        let value: Double
        let at: Date
    }

    public init() {}

    /// A counter that moves in coarse steps (one percent of a large video) shows long, regular pauses between
    /// steps. The tolerance therefore grows to twice the last step interval but never drops below the minimum.
    /// Before a run knows one step interval, only the maximum applies.
    private var gapTolerance: TimeInterval {
        guard smoothed != nil else { return Self.maximumGapTolerance }
        return min(Self.maximumGapTolerance, max(Self.minimumGapTolerance, 2 * lastMovementInterval))
    }

    /// Forgets all samples. Call it whenever the backup does not send: paused, waiting, offline, finished.
    public mutating func reset() {
        self = BackupUploadSpeedEstimator()
    }

    /// Feeds the sent-bytes counter. The first sample after `init` or `reset` is only the baseline.
    public mutating func record(bytes: Int64, at time: Date) {
        guard let previousBytes = lastBytes else {
            lastBytes = bytes
            return
        }
        // A smaller counter belongs to a new runner; its history does not continue this one.
        guard bytes >= previousBytes else {
            reset()
            lastBytes = bytes
            return
        }
        guard bytes > previousBytes else { return }
        defer {
            lastBytes = bytes
            lastMovement = time
        }
        guard let previousMovement = lastMovement else { return }
        let interval = time.timeIntervalSince(previousMovement)
        guard interval > 0 else { return }
        if interval > gapTolerance {
            // The old rate is stale: this movement only opens a new run.
            smoothed = nil
            runStart = nil
            shown = nil
            lastMovementInterval = 0
            return
        }
        let rate = Double(bytes - previousBytes) / interval
        if let current = smoothed {
            let weight = 1 - exp(-interval / Self.timeConstant)
            smoothed = current + weight * (rate - current)
        } else {
            smoothed = rate
            runStart = previousMovement
        }
        lastMovementInterval = interval
    }

    /// The speed to show now, or nil. Reading may start a new display interval, so it mutates.
    public mutating func speed(at time: Date) -> Double? {
        guard let smoothed, let lastMovement, let runStart,
            time.timeIntervalSince(lastMovement) <= gapTolerance,
            time.timeIntervalSince(runStart) >= Self.warmUp
        else {
            shown = nil
            return nil
        }
        if let shown, time.timeIntervalSince(shown.at) < Self.displayInterval, time >= shown.at {
            return shown.value
        }
        shown = Shown(value: smoothed, at: time)
        return smoothed
    }
}
