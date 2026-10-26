import Foundation

public enum LibraryHeavyWorkload: String, Sendable, Equatable {
    case mlModelLoading
    case mlInference
    case mlIndexing
    case backupMaterialization
    case backupHashing
    case cryptoPreparation
    case videoDerivative
    /// The timeline order pass and the thumbnail crawl ask for admission only in an iOS background window.
    case timelineOrderPass
    case thumbnailCrawl

    /// Automatic work that fills the disk pauses while storage is critical. Backup is excluded: it checks
    /// free space itself and tells the person that the device needs storage.
    public var writesLargeData: Bool {
        switch self {
        case .mlIndexing, .videoDerivative, .thumbnailCrawl: true
        case .mlModelLoading, .mlInference, .backupHashing, .backupMaterialization, .cryptoPreparation,
            .timelineOrderPass:
            false
        }
    }

    /// Backup preparation mostly waits for PhotoKit reads and iCloud downloads, so a few photos may prepare at once.
    /// Every other workload holds admission alone.
    var sharesAdmission: Bool {
        switch self {
        case .backupMaterialization, .backupHashing: true
        case .mlModelLoading, .mlInference, .mlIndexing, .cryptoPreparation, .videoDerivative, .timelineOrderPass,
            .thumbnailCrawl:
            false
        }
    }
}

public enum LibraryWorkIntent: Int, Sendable, Comparable, Equatable {
    case maintenance = 0
    case automatic = 1
    case userInitiated = 2
    case interactive = 3

    public static func < (lhs: LibraryWorkIntent, rhs: LibraryWorkIntent) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum LibraryWorkMemoryClass: Int, Sendable, Comparable, Equatable {
    case small = 0
    case medium = 1
    case large = 2

    public static func < (lhs: LibraryWorkMemoryClass, rhs: LibraryWorkMemoryClass) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct LibraryWorkDemand: Sendable, Equatable {
    public var maximumInternalParallelism: Int
    public var maximumItemsPerQuantum: Int
    public var maximumWallTime: Duration?

    public init(
        maximumInternalParallelism: Int,
        maximumItemsPerQuantum: Int,
        maximumWallTime: Duration? = nil
    ) {
        self.maximumInternalParallelism = max(1, maximumInternalParallelism)
        self.maximumItemsPerQuantum = max(1, maximumItemsPerQuantum)
        self.maximumWallTime = maximumWallTime.flatMap { $0 > .zero ? $0 : nil }
    }
}

public struct LibraryWorkRequest: Sendable, Equatable {
    public var workload: LibraryHeavyWorkload
    public var intent: LibraryWorkIntent
    public var memoryClass: LibraryWorkMemoryClass
    public var demand: LibraryWorkDemand?

    public init(
        workload: LibraryHeavyWorkload,
        intent: LibraryWorkIntent,
        memoryClass: LibraryWorkMemoryClass = .medium,
        demand: LibraryWorkDemand? = nil
    ) {
        self.workload = workload
        self.intent = intent
        self.memoryClass = memoryClass
        self.demand = demand
    }
}

public enum LibraryWorkPolicyReason: String, Sendable, Equatable {
    case nominal
    case fairPressure
    case visibleDemand
    case seriousPressure
    case criticalPressure
    case lowPowerMode
    case executionSuspended
    case recoveryHysteresis
    case storagePressure
}

public struct LibraryWorkBudget: Sendable, Equatable {
    public var isAdmitted: Bool
    public var internalParallelism: Int
    public var maxItemsPerQuantum: Int
    public var maximumWallTime: Duration?
    /// The most permits that may hold admission together with this one, this one included. One means it runs alone.
    public var concurrentPermits: Int
    public var memoryTier: MemoryBudgetTier
    public var reason: LibraryWorkPolicyReason
    public var snapshotGeneration: UInt64

    public init(
        isAdmitted: Bool,
        internalParallelism: Int,
        maxItemsPerQuantum: Int,
        maximumWallTime: Duration? = nil,
        concurrentPermits: Int = 1,
        memoryTier: MemoryBudgetTier,
        reason: LibraryWorkPolicyReason,
        snapshotGeneration: UInt64
    ) {
        self.isAdmitted = isAdmitted
        self.internalParallelism = max(0, internalParallelism)
        self.maxItemsPerQuantum = max(0, maxItemsPerQuantum)
        self.maximumWallTime = maximumWallTime.flatMap { $0 > .zero ? $0 : nil }
        self.concurrentPermits = max(0, concurrentPermits)
        self.memoryTier = memoryTier
        self.reason = reason
        self.snapshotGeneration = snapshotGeneration
    }
}

public enum LibraryWorkYieldReason: String, Sendable, Equatable {
    case timeSliceCompleted
    case higherPriorityWork
    case visibleDemand
    case userInteraction
    case thermalPressure
    case memoryPressure
    case storagePressure
    case lowPowerMode
    case executionSuspended
    case generationChanged
    case cancelled
}

public enum LibraryWorkContinuationDecision: Sendable, Equatable {
    case continueWork
    case yield(LibraryWorkYieldReason)
}

public struct LibraryWorkLease: Sendable {
    public let budget: LibraryWorkBudget
    private let decision: @Sendable () -> LibraryWorkContinuationDecision
    private let waitForYield: @Sendable () async -> LibraryWorkYieldReason?
    private let runtimeSnapshot: @Sendable () -> LibraryRuntimeSnapshot
    #if DEBUG
        /// Debug-only seam, set where the coordinator creates the lease.
        fileprivate var yieldWaitEvaluationCount: @Sendable () -> Int = { 0 }
    #endif

    fileprivate init(
        budget: LibraryWorkBudget,
        decision: @escaping @Sendable () -> LibraryWorkContinuationDecision,
        waitForYield: @escaping @Sendable () async -> LibraryWorkYieldReason?,
        runtimeSnapshot: @escaping @Sendable () -> LibraryRuntimeSnapshot
    ) {
        self.budget = budget
        self.decision = decision
        self.waitForYield = waitForYield
        self.runtimeSnapshot = runtimeSnapshot
    }

    #if DEBUG
        /// Debug-only seam: how often `nextYield` evaluated the decision, so a test can tell that the wait is in place.
        var yieldWaitEvaluations: Int { yieldWaitEvaluationCount() }
    #endif

    /// Feature code consults this only at an asset/chunk/file boundary. It never interrupts a
    /// remote commit or an already-running framework inference.
    public func shouldContinue() -> Bool {
        continuationDecision() == .continueWork
    }

    public func continuationDecision() -> LibraryWorkContinuationDecision { decision() }

    /// Waits until this lease should yield and returns why. It checks again on each runtime change, when a waiter with
    /// a higher intent arrives, and at the end of the time slice; it never polls. Nil when the caller is cancelled.
    public func nextYield() async -> LibraryWorkYieldReason? { await waitForYield() }

    /// Privacy-safe scalar resource classes used by Core diagnostics before and after a quantum.
    public func currentRuntimeSnapshot() -> LibraryRuntimeSnapshot { runtimeSnapshot() }
}

public struct LibraryResourceCoordinatorMetrics: Sendable, Equatable {
    public var permitsAcquired: Int
    public var permitsReleased: Int
    public var cancelledWaiters: Int
    public var policyPauses: Int
    public var recoveries: Int
    public var maximumConcurrentPermits: Int
    public var maximumWaitMilliseconds: UInt64

    public init(
        permitsAcquired: Int = 0,
        permitsReleased: Int = 0,
        cancelledWaiters: Int = 0,
        policyPauses: Int = 0,
        recoveries: Int = 0,
        maximumConcurrentPermits: Int = 0,
        maximumWaitMilliseconds: UInt64 = 0
    ) {
        self.permitsAcquired = permitsAcquired
        self.permitsReleased = permitsReleased
        self.cancelledWaiters = cancelledWaiters
        self.policyPauses = policyPauses
        self.recoveries = recoveries
        self.maximumConcurrentPermits = maximumConcurrentPermits
        self.maximumWaitMilliseconds = maximumWaitMilliseconds
    }
}

public struct LibraryResourcePolicy: Sendable, Equatable {
    public init() {}

    public func budget(
        for request: LibraryWorkRequest,
        snapshot: LibraryRuntimeSnapshot,
        recoveryIsPending: Bool = false
    ) -> LibraryWorkBudget {
        func result(
            _ admitted: Bool,
            _ items: Int,
            _ reason: LibraryWorkPolicyReason,
            honorsDemand: Bool = false,
            maximumParallelism: Int = 1,
            maximumWallTime: Duration? = nil,
            concurrentPermits: Int = 1
        ) -> LibraryWorkBudget {
            let demand = honorsDemand ? request.demand : nil
            return LibraryWorkBudget(
                isAdmitted: admitted,
                internalParallelism: admitted
                    ? min(maximumParallelism, demand?.maximumInternalParallelism ?? 1)
                    : 0,
                maxItemsPerQuantum: admitted ? min(items, demand?.maximumItemsPerQuantum ?? items) : 0,
                maximumWallTime: admitted
                    ? Self.shorter(demand?.maximumWallTime, maximumWallTime)
                    : nil,
                concurrentPermits: admitted ? concurrentPermits : 0,
                memoryTier: snapshot.memoryBudgetTier,
                reason: reason,
                snapshotGeneration: snapshot.generation
            )
        }

        // Backup preparation shares admission only in the foreground with full memory budgets: three photos at
        // nominal and two at fair thermal pressure. Serious pressure, Low Power Mode and the background keep one.
        func sharedPermits(_ limit: Int) -> Int {
            guard request.workload.sharesAdmission, snapshot.memoryBudgetTier == .normal else { return 1 }
            switch snapshot.executionOpportunity {
            case .foregroundActive, .foregroundInactive: return limit
            case .backgroundPermitted, .suspended: return 1
            }
        }

        if snapshot.executionOpportunity == .suspended {
            return result(false, 0, .executionSuspended)
        }
        if snapshot.thermalLevel == .critical || snapshot.memoryPressure == .critical
            || snapshot.memoryHeadroom == .critical
        {
            return result(false, 0, .criticalPressure)
        }
        if snapshot.storagePressure == .critical, request.intent < .userInitiated,
            request.workload.writesLargeData
        {
            return result(false, 0, .storagePressure)
        }
        if recoveryIsPending, request.intent < .interactive {
            return result(false, 0, .recoveryHysteresis)
        }
        if snapshot.thermalLevel == .serious || snapshot.memoryPressure == .warning
            || snapshot.memoryHeadroom == .constrained
        {
            let isSmallInteractiveInference =
                request.workload == .mlInference
                && request.intent == .interactive && request.memoryClass == .small
            let isUserBackupPreparation =
                request.intent >= .userInitiated
                && {
                    switch request.workload {
                    case .backupMaterialization, .backupHashing, .cryptoPreparation: true
                    case .mlModelLoading, .mlInference, .mlIndexing, .videoDerivative, .timelineOrderPass,
                        .thumbnailCrawl:
                        false
                    }
                }()
            guard isSmallInteractiveInference || isUserBackupPreparation else {
                return result(false, 0, .seriousPressure)
            }
            return result(true, 1, .seriousPressure)
        }
        if request.intent < .userInitiated,
            snapshot.activeVideoPlaybackCount > 0 || snapshot.activeUserTransferCount > 0
                || snapshot.activeSearchCount > 0
        {
            return result(false, 0, .visibleDemand)
        }
        if snapshot.hasVisibleMediaDemand || snapshot.hasActiveUserInteraction {
            guard request.intent == .interactive else {
                return result(false, 0, .visibleDemand)
            }
        }
        if snapshot.isLowPowerMode {
            switch request.workload {
            case .mlModelLoading, .mlIndexing, .videoDerivative, .timelineOrderPass, .thumbnailCrawl:
                guard request.intent >= .userInitiated else {
                    return result(false, 0, .lowPowerMode)
                }
            case .mlInference, .backupMaterialization, .backupHashing, .cryptoPreparation:
                break
            }
            return result(true, 1, .lowPowerMode)
        }
        if snapshot.thermalLevel == .fair {
            return result(
                true,
                request.intent >= .userInitiated ? 2 : 1,
                .fairPressure,
                honorsDemand: request.workload == .mlIndexing,
                maximumWallTime: request.workload == .mlIndexing ? .milliseconds(500) : nil,
                concurrentPermits: sharedPermits(2)
            )
        }
        if request.workload == .mlIndexing, request.intent == .automatic, request.demand != nil {
            return result(
                true,
                128,
                .nominal,
                honorsDemand: true,
                maximumParallelism: 3
            )
        }
        let items =
            switch request.intent {
            case .interactive: 8
            case .userInitiated: 4
            case .automatic: 2
            case .maintenance: 1
            }
        return result(true, items, .nominal, concurrentPermits: sharedPermits(3))
    }

    private static func shorter(_ lhs: Duration?, _ rhs: Duration?) -> Duration? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)): min(lhs, rhs)
        case (.some(let value), .none), (.none, .some(let value)): value
        case (.none, .none): nil
        }
    }
}

private final class LibraryWorkPreemptionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func snapshot() -> UInt64 { lock.withLock { generation } }

    func signal() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            generation &+= 1
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        resumed.forEach { $0.resume() }
    }

    /// Returns once the signal fired after `generation`, or when the caller is cancelled.
    func wait(after generation: UInt64) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let fired = lock.withLock { () -> Bool in
                    guard self.generation == generation, !Task.isCancelled else { return true }
                    waiters[id] = continuation
                    return false
                }
                if fired { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.resume()
        }
    }
}

private final class LibraryWorkLeaseState: @unchecked Sendable {
    let budget: LibraryWorkBudget

    private let runtimeState: LibraryRuntimeState
    private let policy: LibraryResourcePolicy
    private let request: LibraryWorkRequest
    private let preemptionSignal: LibraryWorkPreemptionSignal
    private let preemptionGeneration: UInt64
    private let deadlineNanoseconds: UInt64?
    private let monotonicNow: @Sendable () -> UInt64
    private let lock = NSLock()
    private var recordedYieldReason: LibraryWorkYieldReason?
    #if DEBUG
        private var yieldWaitEvaluations = 0
    #endif

    init(
        budget: LibraryWorkBudget,
        runtimeState: LibraryRuntimeState,
        policy: LibraryResourcePolicy,
        request: LibraryWorkRequest,
        preemptionSignal: LibraryWorkPreemptionSignal,
        acquiredAt: UInt64,
        monotonicNow: @escaping @Sendable () -> UInt64
    ) {
        self.budget = budget
        self.runtimeState = runtimeState
        self.policy = policy
        self.request = request
        self.preemptionSignal = preemptionSignal
        self.preemptionGeneration = preemptionSignal.snapshot()
        self.monotonicNow = monotonicNow
        self.deadlineNanoseconds = budget.maximumWallTime.flatMap {
            Self.deadline(start: acquiredAt, duration: $0)
        }
    }

    func decision() -> LibraryWorkContinuationDecision {
        let reason: LibraryWorkYieldReason?
        if Task.isCancelled {
            reason = .cancelled
        } else {
            let snapshot = runtimeState.snapshot()
            reason =
                liveYieldReason(snapshot: snapshot)
                ?? preemptionYieldReason()
                ?? deadlineYieldReason()
        }
        guard let reason else { return .continueWork }
        lock.withLock {
            if recordedYieldReason == nil { recordedYieldReason = reason }
        }
        return .yield(reason)
    }

    func yieldReason() -> LibraryWorkYieldReason? {
        lock.withLock { recordedYieldReason }
    }

    #if DEBUG
        func yieldWaitEvaluationCount() -> Int {
            lock.withLock { yieldWaitEvaluations }
        }
    #endif

    /// Evaluates the decision on each wake: a runtime change (the first is the current snapshot), a preemption, or the
    /// end of the time slice.
    func nextYield() async -> LibraryWorkYieldReason? {
        let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let runtimeChanges = runtimeState.updates()
        let preemptionSignal = self.preemptionSignal
        let preemptionGeneration = self.preemptionGeneration
        let deadlineNanoseconds = self.deadlineNanoseconds
        let monotonicNow = self.monotonicNow
        let watchers = [
            Task {
                for await _ in runtimeChanges { wake.yield() }
            },
            Task {
                await preemptionSignal.wait(after: preemptionGeneration)
                wake.yield()
            },
            Task {
                guard let deadlineNanoseconds else { return }
                let now = monotonicNow()
                if deadlineNanoseconds > now { try? await Task.sleep(nanoseconds: deadlineNanoseconds - now) }
                wake.yield()
            },
        ]
        defer {
            watchers.forEach { $0.cancel() }
            wake.finish()
        }
        for await _ in wakes {
            guard !Task.isCancelled else { return nil }
            let current = decision()
            #if DEBUG
                lock.withLock { yieldWaitEvaluations += 1 }
            #endif
            if case .yield(let reason) = current { return reason }
        }
        return nil
    }

    private func liveYieldReason(snapshot: LibraryRuntimeSnapshot) -> LibraryWorkYieldReason? {
        if snapshot.generation != budget.snapshotGeneration { return .generationChanged }
        if snapshot.executionOpportunity == .suspended { return .executionSuspended }
        if snapshot.storagePressure == .critical, request.intent < .userInitiated,
            request.workload.writesLargeData
        {
            return .storagePressure
        }
        if snapshot.hasActiveUserInteraction { return .userInteraction }
        if snapshot.hasVisibleMediaDemand { return .visibleDemand }
        if snapshot.isLowPowerMode, request.workload == .mlIndexing, request.intent < .userInitiated {
            return .lowPowerMode
        }
        if snapshot.thermalLevel == .serious || snapshot.thermalLevel == .critical {
            return .thermalPressure
        }
        if snapshot.memoryPressure != .normal || snapshot.memoryHeadroom == .constrained
            || snapshot.memoryHeadroom == .critical
        {
            return .memoryPressure
        }

        let current = policy.budget(for: request, snapshot: snapshot)
        if !current.isAdmitted {
            return Self.yieldReason(for: current.reason)
        }
        if current.internalParallelism < budget.internalParallelism
            || current.maxItemsPerQuantum < budget.maxItemsPerQuantum
        {
            return Self.yieldReason(for: current.reason)
        }
        return nil
    }

    private func preemptionYieldReason() -> LibraryWorkYieldReason? {
        preemptionSignal.snapshot() == preemptionGeneration ? nil : .higherPriorityWork
    }

    private func deadlineYieldReason() -> LibraryWorkYieldReason? {
        guard let deadlineNanoseconds, monotonicNow() >= deadlineNanoseconds else { return nil }
        return .timeSliceCompleted
    }

    private static func yieldReason(for reason: LibraryWorkPolicyReason) -> LibraryWorkYieldReason {
        switch reason {
        case .visibleDemand: .visibleDemand
        case .seriousPressure, .criticalPressure:
            .thermalPressure
        case .lowPowerMode: .lowPowerMode
        case .storagePressure: .storagePressure
        case .executionSuspended: .executionSuspended
        case .nominal, .fairPressure, .recoveryHysteresis:
            .thermalPressure
        }
    }

    private static func deadline(start: UInt64, duration: Duration) -> UInt64? {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return nil }
        let seconds = UInt64(components.seconds)
        let nanoseconds = UInt64(components.attoseconds / 1_000_000_000)
        let (wholeSeconds, secondsOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !secondsOverflow else { return UInt64.max }
        let (interval, intervalOverflow) = wholeSeconds.addingReportingOverflow(nanoseconds)
        guard !intervalOverflow else { return UInt64.max }
        let (deadline, deadlineOverflow) = start.addingReportingOverflow(interval)
        return deadlineOverflow ? UInt64.max : deadline
    }
}

/// Admission owner for CPU/RAM-heavy local work. It never owns feature jobs or network transfers.
/// A scoped permit that releases its own slot prevents cancellation/error paths from leaking admission.
/// Each permit runs alone unless its budget lets backup preparation share admission.
public actor LibraryResourceCoordinator {
    public static let shared = LibraryResourceCoordinator(runtimeState: .shared)

    private struct Waiter {
        let id: UUID
        let sequence: UInt64
        let generation: UInt64
        let request: LibraryWorkRequest
        let enqueuedAt: UInt64
        var hasRecordedPolicyPause: Bool
        let continuation: CheckedContinuation<LibraryWorkLease, any Error>
    }

    private struct ActivePermit {
        let id: UUID
        let request: LibraryWorkRequest
        let budget: LibraryWorkBudget
        let leaseState: LibraryWorkLeaseState
        let acquiredAt: UInt64
    }

    private let runtimeState: LibraryRuntimeState
    private let policy: LibraryResourcePolicy
    private let recoveryDelay: Duration
    private let recoverySleep: @Sendable (Duration) async throws -> Void
    private let monotonicNow: @Sendable () -> UInt64
    private let preemptionSignal = LibraryWorkPreemptionSignal()
    private var waiters: [Waiter] = []
    private var activePermits: [UUID: ActivePermit] = [:]
    private var sequence: UInt64 = 0
    private var observedSnapshot: LibraryRuntimeSnapshot
    private var effectiveSnapshot: LibraryRuntimeSnapshot
    private var recoveryIsPending = false
    private var recoveryTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private var collectedMetrics = LibraryResourceCoordinatorMetrics()
    private var lastLoggedState: String?

    public init(
        runtimeState: LibraryRuntimeState,
        policy: LibraryResourcePolicy = LibraryResourcePolicy(),
        recoveryDelay: Duration = .seconds(30),
        monotonicNow: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.runtimeState = runtimeState
        self.policy = policy
        self.recoveryDelay = recoveryDelay
        recoverySleep = { try await Task.sleep(for: $0) }
        self.monotonicNow = monotonicNow
        let snapshot = runtimeState.snapshot()
        observedSnapshot = snapshot
        effectiveSnapshot = snapshot
    }

    init(
        runtimeState: LibraryRuntimeState,
        policy: LibraryResourcePolicy = LibraryResourcePolicy(),
        recoveryDelay: Duration,
        monotonicNow: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        recoverySleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.runtimeState = runtimeState
        self.policy = policy
        self.recoveryDelay = recoveryDelay
        self.recoverySleep = recoverySleep
        self.monotonicNow = monotonicNow
        let snapshot = runtimeState.snapshot()
        observedSnapshot = snapshot
        effectiveSnapshot = snapshot
    }

    deinit {
        recoveryTask?.cancel()
        observationTask?.cancel()
    }

    public func startObserving() {
        guard observationTask == nil else { return }
        let updates = runtimeState.updates()
        observationTask = Task { [weak self] in
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                await self?.observe(snapshot)
            }
        }
    }

    public func metrics() -> LibraryResourceCoordinatorMetrics { collectedMetrics }

    var waitingPermitCount: Int { waiters.count }

    var observedGeneration: UInt64 { observedSnapshot.generation }

    public func budget(for request: LibraryWorkRequest) -> LibraryWorkBudget {
        policy.budget(
            for: request,
            snapshot: effectiveSnapshot,
            recoveryIsPending: recoveryIsPending
        )
    }

    public func withHeavyPermit<T: Sendable>(
        _ request: LibraryWorkRequest,
        operation: @Sendable (LibraryWorkLease) async throws -> T
    ) async throws -> T {
        let permitID = UUID()
        let lease = try await acquire(id: permitID, request: request)
        defer { release(id: permitID) }
        try Task.checkCancellation()
        return try await operation(lease)
    }

    private func acquire(id: UUID, request: LibraryWorkRequest) async throws -> LibraryWorkLease {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sequence &+= 1
                waiters.append(
                    Waiter(
                        id: id, sequence: sequence, generation: effectiveSnapshot.generation,
                        request: request, enqueuedAt: monotonicNow(),
                        hasRecordedPolicyPause: false, continuation: continuation
                    ))
                if activePermits.values.contains(where: { request.intent > $0.request.intent }) {
                    preemptionSignal.signal()
                }
                admitNextIfPossible()
            }
        } onCancel: {
            Task { await self.cancelWaiting(id: id) }
        }
    }

    private func cancelWaiting(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        collectedMetrics.cancelledWaiters += 1
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(id: UUID) {
        guard let permit = activePermits.removeValue(forKey: id) else { return }
        collectedMetrics.permitsReleased += 1
        let duration = Self.milliseconds(from: permit.acquiredAt, to: monotonicNow())
        PhotoDiagnostics.shared.emit(
            "ResourcePermit",
            [
                "action": "release",
                "active": "\(activePermits.count)",
                "durationMs": "\(duration)",
                "intent": String(describing: permit.request.intent),
                "reason": permit.budget.reason.rawValue,
                "workload": permit.request.workload.rawValue,
                "yieldReason": permit.leaseState.yieldReason()?.rawValue ?? "completed",
            ])
        admitNextIfPossible()
    }

    /// The smallest limit of the running permits. A permit that runs alone stops admission, as the single slot did.
    private var runningPermitLimit: Int { activePermits.values.map(\.budget.concurrentPermits).min() ?? .max }

    private func admitNextIfPossible() {
        while activePermits.count < runningPermitLimit, admitNextWaiter() {}
    }

    /// Admits the first waiter in priority order that the policy admits, and returns whether the queue changed.
    /// That waiter holds back every waiter behind it until it fits beside the running permits, so shared backup
    /// permits cannot starve exclusive or higher-priority work.
    private func admitNextWaiter() -> Bool {
        let ordered = waiters.indices.sorted {
            let lhs = waiters[$0]
            let rhs = waiters[$1]
            if lhs.request.intent != rhs.request.intent { return lhs.request.intent > rhs.request.intent }
            return lhs.sequence < rhs.sequence
        }
        for index in ordered {
            let candidate = waiters[index]
            if candidate.generation != effectiveSnapshot.generation {
                waiters.remove(at: index)
                candidate.continuation.resume(throwing: CancellationError())
                return true
            }
            let budget = budget(for: candidate.request)
            guard budget.isAdmitted else {
                if !candidate.hasRecordedPolicyPause {
                    waiters[index].hasRecordedPolicyPause = true
                    collectedMetrics.policyPauses += 1
                }
                continue
            }
            guard activePermits.count < budget.concurrentPermits else { return false }
            waiters.remove(at: index)
            let now = monotonicNow()
            let leaseState = LibraryWorkLeaseState(
                budget: budget,
                runtimeState: runtimeState,
                policy: policy,
                request: candidate.request,
                preemptionSignal: preemptionSignal,
                acquiredAt: now,
                monotonicNow: monotonicNow
            )
            activePermits[candidate.id] = ActivePermit(
                id: candidate.id,
                request: candidate.request,
                budget: budget,
                leaseState: leaseState,
                acquiredAt: now
            )
            collectedMetrics.permitsAcquired += 1
            collectedMetrics.maximumConcurrentPermits = max(
                collectedMetrics.maximumConcurrentPermits, activePermits.count)
            let wait = Self.milliseconds(from: candidate.enqueuedAt, to: now)
            collectedMetrics.maximumWaitMilliseconds = max(collectedMetrics.maximumWaitMilliseconds, wait)
            PhotoDiagnostics.shared.emit(
                "ResourcePermit",
                [
                    "action": candidate.hasRecordedPolicyPause ? "resume" : "acquire",
                    "active": "\(activePermits.count)",
                    "intent": String(describing: candidate.request.intent),
                    "reason": budget.reason.rawValue,
                    "waitMs": "\(wait)",
                    "workload": candidate.request.workload.rawValue,
                ])
            let runtimeState = self.runtimeState
            var lease = LibraryWorkLease(
                budget: budget,
                decision: { leaseState.decision() },
                waitForYield: { await leaseState.nextYield() },
                runtimeSnapshot: { runtimeState.snapshot() }
            )
            #if DEBUG
                lease.yieldWaitEvaluationCount = { leaseState.yieldWaitEvaluationCount() }
            #endif
            candidate.continuation.resume(returning: lease)
            return true
        }
        return false
    }

    private func observe(_ snapshot: LibraryRuntimeSnapshot) {
        observedSnapshot = snapshot
        recoveryTask?.cancel()
        recoveryTask = nil
        if Self.pressureRank(snapshot) >= Self.pressureRank(effectiveSnapshot)
            || snapshot.generation != effectiveSnapshot.generation
        {
            recoveryIsPending = false
            effectiveSnapshot = snapshot
            emitStateTransition(snapshot)
            admitNextIfPossible()
            return
        }

        recoveryIsPending = true
        // Storage pressure has its own hysteresis. It applies at once in both directions, so a device that
        // frees space does not hold backup or user work behind the recovery delay of the other signals.
        let storageChanged = effectiveSnapshot.storagePressure != snapshot.storagePressure
        effectiveSnapshot.storagePressure = snapshot.storagePressure
        emitStateTransition(snapshot)
        if storageChanged { admitNextIfPossible() }
        recoveryTask = Task { [weak self, recoveryDelay, recoverySleep] in
            try? await recoverySleep(recoveryDelay)
            guard !Task.isCancelled else { return }
            await self?.finishRecovery(expected: snapshot)
        }
    }

    private func finishRecovery(expected: LibraryRuntimeSnapshot) {
        guard observedSnapshot == expected else { return }
        recoveryIsPending = false
        effectiveSnapshot = expected
        recoveryTask = nil
        collectedMetrics.recoveries += 1
        emitStateTransition(expected)
        admitNextIfPossible()
    }

    private func emitStateTransition(_ snapshot: LibraryRuntimeSnapshot) {
        let signature = [
            snapshot.thermalLevel.rawValue.description,
            String(describing: snapshot.memoryBudgetTier),
            String(describing: snapshot.memoryPressure),
            String(describing: snapshot.memoryHeadroom),
            String(describing: snapshot.storagePressure),
            "\(snapshot.isLowPowerMode)",
            String(describing: snapshot.executionOpportunity),
            "\(snapshot.network.isReachable)",
            "\(snapshot.network.isConstrained)",
            "\(snapshot.network.isExpensive)",
            LibraryNetworkState.diagnosticList(snapshot.network.usedInterfaces),
            LibraryNetworkState.diagnosticList(snapshot.network.availableInterfaces),
            "\(snapshot.hasVisibleMediaDemand)",
            "\(snapshot.hasActiveUserInteraction)",
            "\(recoveryIsPending)",
        ].joined(separator: "|")
        guard signature != lastLoggedState else { return }
        lastLoggedState = signature
        PhotoDiagnostics.shared.emit(
            "ResourceState",
            [
                "execution": String(describing: snapshot.executionOpportunity),
                "headroom": String(describing: snapshot.memoryHeadroom),
                "lowPower": "\(snapshot.isLowPowerMode)",
                "memory": String(describing: snapshot.memoryBudgetTier),
                "memoryPressure": String(describing: snapshot.memoryPressure),
                "storagePressure": String(describing: snapshot.storagePressure),
                "networkConstrained": "\(snapshot.network.isConstrained)",
                "networkExpensive": "\(snapshot.network.isExpensive)",
                "networkInterfaces": LibraryNetworkState.diagnosticList(snapshot.network.usedInterfaces),
                "networkAvailableInterfaces": LibraryNetworkState.diagnosticList(snapshot.network.availableInterfaces),
                "networkReachable": "\(snapshot.network.isReachable)",
                "recoveryPending": "\(recoveryIsPending)",
                "thermal": String(describing: snapshot.thermalLevel),
                "userInteraction": "\(snapshot.hasActiveUserInteraction)",
                "visibleDemand": "\(snapshot.hasVisibleMediaDemand)",
            ])
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        guard end >= start else { return 0 }
        return (end - start) / 1_000_000
    }

    private static func pressureRank(_ snapshot: LibraryRuntimeSnapshot) -> Int {
        // Cache resizing alone must not start pressure recovery or delay automatic work.
        let memoryRank =
            switch snapshot.memoryPressure {
            case .normal: 0
            case .warning: 2
            case .critical: 4
            }
        let headroomRank =
            switch snapshot.memoryHeadroom {
            case .unknown, .healthy: 0
            case .constrained: 2
            case .critical: 3
            }
        return max(
            snapshot.thermalLevel == .critical ? 4 : snapshot.thermalLevel.rawValue,
            memoryRank,
            headroomRank,
            snapshot.executionOpportunity == .suspended ? 4 : 0
        )
    }
}
