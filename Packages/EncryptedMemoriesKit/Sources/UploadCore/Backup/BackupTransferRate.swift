import Foundation

/// The upload speed that every platform shows: the growth of `BackupStatus.transferredBytes` over the last few
/// seconds. A smaller total belongs to a new runner and starts a new measurement.
public struct BackupTransferRate: Sendable, Equatable {
    private struct Sample: Sendable, Equatable {
        let time: Date
        let bytes: Int64
    }

    /// Bytes per second across the recorded samples. Nil until they span `minimumSpan`, so the first block of a
    /// transfer never shows as a burst.
    public private(set) var bytesPerSecond: Double?

    private let window: TimeInterval
    private let minimumSpan: TimeInterval
    /// A sample this close to the one before the newest replaces the newest, so frequent status updates keep about
    /// one sample per `resolution`.
    private let resolution: TimeInterval
    private var samples: [Sample] = []

    public init(window: TimeInterval = 10, minimumSpan: TimeInterval = 2, resolution: TimeInterval = 0.5) {
        self.window = max(1, window)
        self.minimumSpan = min(max(0.1, minimumSpan), self.window)
        self.resolution = max(0, resolution)
    }

    public mutating func record(bytes: Int64, at time: Date) {
        if let last = samples.last, bytes < last.bytes || time < last.time {
            samples.removeAll()
        }
        let sample = Sample(time: time, bytes: max(0, bytes))
        if samples.count > 1, time.timeIntervalSince(samples[samples.count - 2].time) < resolution {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }
        // The oldest sample that is at least `window` old stays as the start of the measurement.
        while samples.count > 2, time.timeIntervalSince(samples[1].time) >= window {
            samples.removeFirst()
        }
        guard let first = samples.first, let last = samples.last else {
            bytesPerSecond = nil
            return
        }
        let span = last.time.timeIntervalSince(first.time)
        bytesPerSecond = span >= minimumSpan ? Double(last.bytes - first.bytes) / span : nil
    }
}
