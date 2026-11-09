import Foundation

/// Fixed diagnostic categories. These values never identify a photo, account, request, or pass.
public enum SupportMeasurementKind: Int, CaseIterable, Sendable {
    case indexRebuild, eventUpdate, lineageRepair, timelineReconcile, nodeFactsBatch, viewerRead, timelineLoad
}

public enum SupportMeasurementOutcome: Int, Sendable {
    case success, partial, failure, cancelled
}

public enum SupportMeasurementCounter: Int, CaseIterable, Sendable {
    case unlockSucceeded, decryptSucceeded, nodesRequested, nodesUnique, nodeCallsStarted, nodeCallsReturned,
        factsCreated
}

public enum SupportMeasurementPhase: Int, Sendable {
    case enumeration, tags
}

public enum SupportMeasurementTimelineSource: Int, Sendable {
    case notRecorded, sdkCache, authoritative, localStore
}

public enum SupportMeasurementQueue: Int, CaseIterable, Sendable {
    case api, storageDownload, storageUpload
}

/// The new section contains only integers and fixed-size counter arrays. Availability zero means unavailable.
public struct SupportWorkMeasurementSnapshot: Codable, Equatable, Sendable {
    public struct Sample: Codable, Equatable, Sendable {
        public let outcome: Int
        /// Slots follow SupportMeasurementCounter, in declaration order.
        public let counters: [Int]
        public let timelineSource: Int
        /// -1 means that this phase did not run. Other values select the seven duration classes.
        public let enumerationClass: Int
        public let tagsClass: Int
        public let totalClass: Int
    }

    public struct Passes: Codable, Equatable, Sendable {
        public let kind: Int
        public var started = 0
        public var completed = 0
        public var inProgress = 0
        public var droppedSamples = 0
        /// Completed passes only; an in-progress pass is not a measured zero.
        public var counters = Array(repeating: 0, count: SupportMeasurementCounter.allCases.count)
        public var samples: [Sample] = []
    }

    public struct QueueWaits: Codable, Equatable, Sendable {
        public let scope: Int
        public var admitted = Array(repeating: 0, count: 7)
        public var cancelled = Array(repeating: 0, count: 7)
    }

    public let availability: Int
    public let passes: [Passes]
    public let governorWaits: [QueueWaits]

    public static let unavailable = Self(availability: 0, passes: [], governorWaits: [])
}

public protocol SupportWorkMeasurementSource: AnyObject, Sendable {
    func workMeasurementSupportSnapshot() -> SupportWorkMeasurementSnapshot
}

/// One account owns this bounded collector. It never controls work, performs I/O, or retains operation inputs.
public final class SupportWorkMeasurements: SupportWorkMeasurementSource, @unchecked Sendable {
    public static let samplesPerKind = 8
    private static let durationBounds: [Duration] = [
        .seconds(1), .seconds(5), .seconds(15), .seconds(30), .seconds(60), .seconds(120),
    ]
    private static let waitBounds: [Duration] = [
        .milliseconds(1), .milliseconds(10), .milliseconds(100), .seconds(1), .seconds(10), .seconds(60),
    ]

    private let lock = NSLock()
    private let enabled: Bool
    private let clock: @Sendable () -> Duration
    private var closed = false
    private var passes = SupportMeasurementKind.allCases.map {
        SupportWorkMeasurementSnapshot.Passes(kind: $0.rawValue)
    }
    private var waits = SupportMeasurementQueue.allCases.map {
        SupportWorkMeasurementSnapshot.QueueWaits(scope: $0.rawValue)
    }

    public init(enabled: Bool = true, now: (@Sendable () -> Duration)? = nil) {
        self.enabled = enabled
        let origin = ContinuousClock.now
        clock = now ?? { origin.duration(to: .now) }
    }

    public func begin(_ kind: SupportMeasurementKind) -> SupportWorkMeasurementPass? {
        guard enabled else { return nil }
        let admitted = lock.withLock {
            guard !closed else { return false }
            let index = kind.rawValue
            passes[index].started = Self.add(passes[index].started, 1)
            passes[index].inProgress = Self.add(passes[index].inProgress, 1)
            return true
        }
        return admitted ? SupportWorkMeasurementPass(owner: self, kind: kind, started: clock()) : nil
    }

    /// A disabled collector also avoids the clock read, for the unchanged-operation overhead control.
    public func instant() -> Duration? {
        enabled ? clock() : nil
    }

    public func recordQueueWait(_ queue: SupportMeasurementQueue, since start: Duration?, cancelled: Bool) {
        guard enabled, let start else { return }
        let bucket = Self.waitClass(clock() - start)
        lock.withLock {
            guard !closed else { return }
            if cancelled {
                waits[queue.rawValue].cancelled[bucket] = Self.add(waits[queue.rawValue].cancelled[bucket], 1)
            } else {
                waits[queue.rawValue].admitted[bucket] = Self.add(waits[queue.rawValue].admitted[bucket], 1)
            }
        }
    }

    public func close() {
        lock.withLock { closed = true }
    }

    public func workMeasurementSupportSnapshot() -> SupportWorkMeasurementSnapshot {
        lock.withLock {
            guard enabled, !closed else { return .unavailable }
            return SupportWorkMeasurementSnapshot(availability: 1, passes: passes, governorWaits: waits)
        }
    }

    fileprivate func finish(_ kind: SupportMeasurementKind, sample: SupportWorkMeasurementSnapshot.Sample) {
        lock.withLock {
            guard !closed else { return }
            let index = kind.rawValue
            passes[index].completed = Self.add(passes[index].completed, 1)
            passes[index].inProgress = max(0, passes[index].inProgress - 1)
            for slot in passes[index].counters.indices {
                passes[index].counters[slot] = Self.add(passes[index].counters[slot], sample.counters[slot])
            }
            if passes[index].samples.count == Self.samplesPerKind {
                passes[index].samples.removeFirst()
                passes[index].droppedSamples = Self.add(passes[index].droppedSamples, 1)
            }
            passes[index].samples.append(sample)
        }
    }

    fileprivate static func add(_ value: Int, _ amount: Int) -> Int {
        let result = value.addingReportingOverflow(max(0, amount))
        return result.overflow ? Int.max : result.partialValue
    }

    /// [0,1), [1,5), [5,15), [15,30), [30,60), [60,120), [120,infinity) seconds.
    public static func durationClass(_ value: Duration) -> Int {
        durationBounds.firstIndex(where: { value < $0 }) ?? durationBounds.count
    }

    /// [0,1), [1,10), [10,100) ms; [0.1,1), [1,10), [10,60), [60,infinity) seconds.
    public static func waitClass(_ value: Duration) -> Int {
        waitBounds.firstIndex(where: { value < $0 }) ?? waitBounds.count
    }
}

/// Counters belong to one real invocation, including its concurrent child reads. Finishing is idempotent.
public final class SupportWorkMeasurementPass: @unchecked Sendable {
    private let lock = NSLock()
    private let owner: SupportWorkMeasurements
    private let kind: SupportMeasurementKind
    private let started: Duration
    private var finished = false
    private var counters = Array(repeating: 0, count: SupportMeasurementCounter.allCases.count)
    private var source = SupportMeasurementTimelineSource.notRecorded
    private var phases = [-1, -1]

    fileprivate init(owner: SupportWorkMeasurements, kind: SupportMeasurementKind, started: Duration) {
        self.owner = owner
        self.kind = kind
        self.started = started
    }

    public func record(_ counter: SupportMeasurementCounter, count: Int = 1) {
        lock.withLock {
            guard !finished else { return }
            counters[counter.rawValue] = SupportWorkMeasurements.add(counters[counter.rawValue], count)
        }
    }

    public func setTimelineSource(_ source: SupportMeasurementTimelineSource) {
        lock.withLock {
            guard !finished else { return }
            self.source = source
        }
    }

    public func instant() -> Duration? { owner.instant() }

    public func endPhase(_ phase: SupportMeasurementPhase, since start: Duration?) {
        guard let start, let now = owner.instant() else { return }
        let bucket = SupportWorkMeasurements.durationClass(now - start)
        lock.withLock {
            guard !finished else { return }
            phases[phase.rawValue] = bucket
        }
    }

    public func finish(_ outcome: SupportMeasurementOutcome) {
        let sample: SupportWorkMeasurementSnapshot.Sample? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            return .init(
                outcome: outcome.rawValue, counters: counters, timelineSource: source.rawValue,
                enumerationClass: phases[0], tagsClass: phases[1],
                totalClass: SupportWorkMeasurements.durationClass((owner.instant() ?? started) - started))
        }
        if let sample { owner.finish(kind, sample: sample) }
    }
}
