import Foundation
import PhotosCore

enum ProtonRequestScope: CaseIterable, Hashable, Sendable {
    case api
    case storageDownload
    case storageUpload
}

enum ProtonRequestPriority: Int, CaseIterable, Sendable, Comparable {
    case immediate = 0
    case userInitiated = 1
    case foregroundPrefetch = 2
    case background = 3
    case maintenance = 4

    static func < (lhs: ProtonRequestPriority, rhs: ProtonRequestPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum ProtonRequestContext {
    @TaskLocal static var priority: ProtonRequestPriority = .userInitiated
    /// Set by `ProtonRequestCauseScopes.run`; nil in native SDK callbacks.
    @TaskLocal static var cause: ProtonRequestCause?
}

struct ProtonRequestGovernorSnapshot: Sendable, Equatable {
    struct Scope: Sendable, Equatable {
        let inFlight: Int
        let queued: Int
        let concurrencyLimit: Int
        let admissionInterval: TimeInterval
        let admittedLastSecond: Int
        let admittedLastMinute: Int
        let succeededLastSecond: Int
        let succeededLastMinute: Int
        let rateLimitedLastMinute: Int
        let sustainableRateBeforeLastLimit: Int
        let successfulRequestsPerSecondBeforeLastLimit: Double
    }

    let api: Scope
    let storageDownload: Scope
    let storageUpload: Scope

    subscript(scope: ProtonRequestScope) -> Scope {
        switch scope {
        case .api: api
        case .storageDownload: storageDownload
        case .storageUpload: storageUpload
        }
    }
}

/// One adaptive admission point for every Proton API and storage request.
///
/// The governor does not guess a fixed server quota. It observes successful admissions and 429
/// responses, applies server-directed cooldowns, and uses additive increase/multiplicative decrease
/// to find a sustainable rate again. Feature-level work remains concurrent; only network starts are
/// queued here so visible work can overtake background prefetch and backup requests.
actor ProtonRequestGovernor {
    /// A single fetch keeps this handle while demand may join its queued prefetch.
    /// Promotion before enqueue is retained, so it cannot be lost at an actor boundary.
    final class PriorityHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var priority: ProtonRequestPriority

        init(priority: ProtonRequestPriority) { self.priority = priority }
        fileprivate var current: ProtonRequestPriority { lock.withLock { priority } }
        fileprivate func promote(to value: ProtonRequestPriority) {
            lock.withLock { priority = min(priority, value) }
        }
    }

    struct Permit: Sendable {
        fileprivate let id: UUID
        fileprivate let scope: ProtonRequestScope
        fileprivate let label: ProtonRequestLabel?
        fileprivate let cause: String
    }

    struct PriorityScope: Sendable {
        fileprivate let id: UUID
    }

    struct Configuration: Sendable {
        struct Scope: Sendable {
            let initialConcurrency: Int
            let maximumConcurrency: Int
        }

        let api: Scope
        let storageDownload: Scope
        let storageUpload: Scope
        let successWindowForIncrease: Int
        let starvationPromotionInterval: TimeInterval
        let priorityScopeLifetime: TimeInterval
        /// Without a new 429, each interval of this length halves the admission interval and adds one
        /// concurrent request, up to the initial concurrency. A quiet app sends too few requests to reach
        /// `successWindowForIncrease`, so success-based recovery alone kept a 2 s pacing for minutes.
        var rateLimitRecoveryInterval: TimeInterval = 5

        static let production = Configuration(
            api: Scope(initialConcurrency: 4, maximumConcurrency: 8),
            storageDownload: Scope(initialConcurrency: 4, maximumConcurrency: 8),
            storageUpload: Scope(initialConcurrency: 2, maximumConcurrency: 4),
            successWindowForIncrease: 32,
            starvationPromotionInterval: 10,
            priorityScopeLifetime: 60
        )

        func scope(_ value: ProtonRequestScope) -> Scope {
            switch value {
            case .api: api
            case .storageDownload: storageDownload
            case .storageUpload: storageUpload
            }
        }
    }

    private struct Waiter {
        let id: UUID
        var priority: ProtonRequestPriority
        let priorityHandle: PriorityHandle?
        let sequence: UInt64
        let enqueuedAt: Date
        let label: ProtonRequestLabel?
        let cause: String
        let continuation: CheckedContinuation<Permit, Error>
    }

    private struct ScopeState {
        var inFlight = 0
        var activePermitIDs: Set<UUID> = []
        var concurrencyLimit: Int
        let maximumConcurrency: Int
        var admissionInterval: TimeInterval = 0
        var nextAdmission = Date.distantPast
        var cooldownUntil = Date.distantPast
        var successStreak = 0
        var rateLimitStreak = 0
        var waiters: [Waiter] = []
        var admitted: [Date] = []
        var succeeded: [Date] = []
        var rateLimited: [Date] = []
        var sustainableRateBeforeLastLimit = 0
        var successfulRequestsPerSecondBeforeLastLimit: Double = 0
        let initialConcurrency: Int
        /// The last 429 or time-based recovery step; distant past once the scope has fully recovered.
        var lastRecoveryAt = Date.distantPast

        init(configuration: Configuration.Scope) {
            concurrencyLimit = max(1, configuration.initialConcurrency)
            initialConcurrency = concurrencyLimit
            maximumConcurrency = max(concurrencyLimit, configuration.maximumConcurrency)
        }
    }

    private let configuration: Configuration
    private let now: @Sendable () -> Date
    /// Lock-based so a nonisolated caller can open and close a cause without an actor hop.
    nonisolated let causes = ProtonRequestCauseScopes()
    private var tally = ProtonRequestTally()
    private let summaryLog: @Sendable ([String: String]) -> Void
    private var states: [ProtonRequestScope: ScopeState]
    private var sequence: UInt64 = 0
    private var wakeTasks: [ProtonRequestScope: Task<Void, Never>] = [:]
    private var priorityScopes:
        [UUID: (
            priority: ProtonRequestPriority,
            promotedScopes: Set<ProtonRequestScope>,
            suspendedScopes: Set<ProtonRequestScope>,
            expiresAt: Date?
        )] = [:]
    private var priorityWakeTask: Task<Void, Never>?

    init(
        configuration: Configuration = .production,
        now: @escaping @Sendable () -> Date = { Date() },
        summaryLog: @escaping @Sendable ([String: String]) -> Void = {
            PhotoDiagnostics.shared.emitDebug("ProtonRequests", $0)
        }
    ) {
        self.configuration = configuration
        self.now = now
        self.summaryLog = summaryLog
        states = Dictionary(
            uniqueKeysWithValues: ProtonRequestScope.allCases.map {
                ($0, ScopeState(configuration: configuration.scope($0)))
            })
    }

    func acquire(
        scope: ProtonRequestScope,
        priority: ProtonRequestPriority? = nil,
        priorityHandle: PriorityHandle? = nil,
        label: ProtonRequestLabel? = nil
    ) async throws -> Permit {
        try Task.checkCancellation()
        let id = UUID()
        let cause = causes.resolve(taskCause: ProtonRequestContext.cause)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sequence &+= 1
                prunePriorityScopes()
                let requestedPriority = priority ?? ProtonRequestContext.priority
                let scopedPriority = priorityScopes.values
                    .filter { $0.promotedScopes.contains(scope) }
                    .map(\.priority)
                    .min()
                // A caller that supplies `priority` owns that ordering. Only implicit SDK
                // acquisitions inherit the active scope's promotion.
                let effectivePriority =
                    priority == nil
                    ? min(requestedPriority, scopedPriority ?? requestedPriority)
                    : requestedPriority
                states[scope]?.waiters.append(
                    Waiter(
                        id: id,
                        priority: min(effectivePriority, priorityHandle?.current ?? effectivePriority),
                        priorityHandle: priorityHandle,
                        sequence: sequence,
                        enqueuedAt: now(),
                        label: label,
                        cause: cause,
                        continuation: continuation
                    ))
                drain(scope)
            }
        } onCancel: {
            Task { await self.cancel(id: id, scope: scope) }
        }
    }

    /// Changes only this fetch. Already admitted requests keep their permit and transport.
    func promote(_ handle: PriorityHandle, to priority: ProtonRequestPriority) {
        handle.promote(to: priority)
        for scope in ProtonRequestScope.allCases {
            guard var state = states[scope] else { continue }
            for index in state.waiters.indices where state.waiters[index].priorityHandle === handle {
                state.waiters[index].priority = min(state.waiters[index].priority, handle.current)
            }
            states[scope] = state
            drain(scope)
        }
    }

    func beginPriorityScope(
        _ priority: ProtonRequestPriority,
        promoting promotedScopes: Set<ProtonRequestScope> = Set(ProtonRequestScope.allCases),
        suspending suspendedScopes: Set<ProtonRequestScope> = [],
        expiresAfter: TimeInterval? = nil
    ) -> PriorityScope {
        let scope = PriorityScope(id: UUID())
        priorityScopes[scope.id] = (
            priority,
            promotedScopes,
            suspendedScopes,
            expiresAfter.map { now().addingTimeInterval($0) }
        )
        schedulePriorityWake()
        return scope
    }

    /// Starts a scope for an SDK callback path that might not report completion.
    ///
    /// Structured operations must use `beginPriorityScope` and end the returned lease explicitly.
    /// This watchdog is limited to the unstructured callback boundary.
    func beginUnstructuredPriorityScope(
        _ priority: ProtonRequestPriority,
        promoting promotedScopes: Set<ProtonRequestScope> = Set(ProtonRequestScope.allCases),
        suspending suspendedScopes: Set<ProtonRequestScope> = []
    ) -> PriorityScope {
        beginPriorityScope(
            priority,
            promoting: promotedScopes,
            suspending: suspendedScopes,
            expiresAfter: configuration.priorityScopeLifetime
        )
    }

    func endPriorityScope(_ scope: PriorityScope) {
        priorityScopes.removeValue(forKey: scope.id)
        drainAllScopes()
        schedulePriorityWake()
    }

    /// Runs one bounded request with targeted promotion and admission suspension.
    /// The `defer` keeps cancellation and thrown transport errors from leaking the scope.
    func withPriorityScope<T: Sendable>(
        _ priority: ProtonRequestPriority,
        promoting promotedScopes: Set<ProtonRequestScope>,
        suspending suspendedScopes: Set<ProtonRequestScope>,
        operation: () async throws -> T
    ) async rethrows -> T {
        let scope = beginPriorityScope(
            priority,
            promoting: promotedScopes,
            suspending: suspendedScopes
        )
        defer { endPriorityScope(scope) }
        return try await operation()
    }

    func finish(
        _ permit: Permit,
        statusCode: Int?,
        retryAfter: TimeInterval? = nil,
        cancelled: Bool = false
    ) {
        guard var state = states[permit.scope], state.activePermitIDs.remove(permit.id) != nil else { return }
        state.inFlight = max(0, state.inFlight - 1)
        let timestamp = now()
        let summary = tally.record(
            ProtonRequestTally.Key(
                scope: permit.scope,
                method: permit.label?.method ?? "OTHER",
                endpoint: permit.label?.endpoint ?? "<unlabeled>",
                cause: permit.cause,
                status: ProtonRequestStatusClass(statusCode: statusCode, cancelled: cancelled)
            ),
            at: timestamp
        )
        if let summary { summaryLog(summary) }

        if statusCode == 429 {
            state.rateLimited.append(timestamp)
            let successesLastSecond = Self.countRecent(state.succeeded, since: timestamp.addingTimeInterval(-1))
            let successesLastMinute = Self.countRecent(state.succeeded, since: timestamp.addingTimeInterval(-60))
            state.sustainableRateBeforeLastLimit = successesLastMinute
            state.successfulRequestsPerSecondBeforeLastLimit = max(
                Double(successesLastSecond),
                Double(successesLastMinute) / 60
            )
            state.rateLimitStreak += 1
            state.successStreak = 0
            state.concurrencyLimit = max(1, state.concurrencyLimit / 2)

            let fallback = min(30, pow(2, Double(min(state.rateLimitStreak, 5))))
            let cooldown = max(1, min(retryAfter ?? fallback, 120))
            let previousCooldownEnd = max(state.cooldownUntil, timestamp)
            state.cooldownUntil = max(state.cooldownUntil, timestamp.addingTimeInterval(cooldown))
            tally.recordRateLimit(
                scope: permit.scope, retryAfter: retryAfter,
                cooldownFrom: previousCooldownEnd, until: state.cooldownUntil)
            let observedInterval = 1 / max(0.1, state.successfulRequestsPerSecondBeforeLastLimit * 0.8)
            state.admissionInterval = max(0.025, min(2, max(state.admissionInterval * 2, observedInterval)))
            state.lastRecoveryAt = timestamp
            DebugLog.log(
                "[RequestGovernor] 429 scope=\(permit.scope) cooldownMs=\(Int(cooldown * 1_000)) "
                    + "limit=\(state.concurrencyLimit) intervalMs=\(Int(state.admissionInterval * 1_000)) "
                    + "observedRps=\(String(format: "%.1f", state.successfulRequestsPerSecondBeforeLastLimit)) "
                    + "success60s=\(successesLastMinute)"
            )
        } else if let statusCode, (200...399).contains(statusCode) {
            state.succeeded.append(timestamp)
            state.successStreak += 1
            if state.successStreak >= configuration.successWindowForIncrease {
                state.successStreak = 0
                state.rateLimitStreak = 0
                state.concurrencyLimit = min(state.maximumConcurrency, state.concurrencyLimit + 1)
                state.admissionInterval *= 0.8
                if state.admissionInterval < 0.01 { state.admissionInterval = 0 }
            }
        }

        Self.prune(&state, now: timestamp)
        states[permit.scope] = state
        drain(permit.scope)
    }

    func snapshot() -> ProtonRequestGovernorSnapshot {
        prunePriorityScopes()
        let timestamp = now()
        return ProtonRequestGovernorSnapshot(
            api: snapshot(.api, now: timestamp),
            storageDownload: snapshot(.storageDownload, now: timestamp),
            storageUpload: snapshot(.storageUpload, now: timestamp)
        )
    }

    private func snapshot(_ scope: ProtonRequestScope, now timestamp: Date) -> ProtonRequestGovernorSnapshot.Scope {
        guard var state = states[scope] else {
            return .init(
                inFlight: 0, queued: 0, concurrencyLimit: 1, admissionInterval: 0,
                admittedLastSecond: 0, admittedLastMinute: 0, succeededLastSecond: 0,
                succeededLastMinute: 0, rateLimitedLastMinute: 0,
                sustainableRateBeforeLastLimit: 0,
                successfulRequestsPerSecondBeforeLastLimit: 0
            )
        }
        Self.prune(&state, now: timestamp)
        recover(&state, now: timestamp)
        states[scope] = state
        return .init(
            inFlight: state.inFlight,
            queued: state.waiters.count,
            concurrencyLimit: state.concurrencyLimit,
            admissionInterval: state.admissionInterval,
            admittedLastSecond: Self.countRecent(state.admitted, since: timestamp.addingTimeInterval(-1)),
            admittedLastMinute: state.admitted.count,
            succeededLastSecond: Self.countRecent(state.succeeded, since: timestamp.addingTimeInterval(-1)),
            succeededLastMinute: state.succeeded.count,
            rateLimitedLastMinute: state.rateLimited.count,
            sustainableRateBeforeLastLimit: state.sustainableRateBeforeLastLimit,
            successfulRequestsPerSecondBeforeLastLimit: state.successfulRequestsPerSecondBeforeLastLimit
        )
    }

    /// Counts since the backend was built plus the live state of every scope, for the support report.
    func requestSupportSnapshot() -> RemoteRequestSupportSnapshot {
        let live = snapshot()
        let counts = tally.counts
            .map { key, count in
                RemoteRequestSupportSnapshot.Count(
                    scope: key.scope.supportName, method: key.method, endpoint: key.endpoint,
                    cause: key.cause, status: key.status.rawValue, count: count)
            }
            .sorted {
                ($0.scope, $0.cause, $0.endpoint, $0.method, $0.status)
                    < ($1.scope, $1.cause, $1.endpoint, $1.method, $1.status)
            }
        let scopes = ProtonRequestScope.allCases.map { scope in
            let state = live[scope]
            let totals = tally.scopes[scope] ?? ProtonRequestTally.ScopeTotals()
            return RemoteRequestSupportSnapshot.Scope(
                scope: scope.supportName,
                inFlight: state.inFlight,
                queued: state.queued,
                concurrencyLimit: state.concurrencyLimit,
                admissionIntervalMilliseconds: Int((state.admissionInterval * 1_000).rounded()),
                admittedLastMinute: state.admittedLastMinute,
                rateLimitedLastMinute: state.rateLimitedLastMinute,
                peakInFlight: totals.peakInFlight,
                maximumRetryAfterSeconds: totals.maximumRetryAfter,
                totalCooldownSeconds: totals.cooldownSeconds
            )
        }
        return RemoteRequestSupportSnapshot(counts: counts, overflowRequests: tally.overflowRequests, scopes: scopes)
    }

    private func cancel(id: UUID, scope: ProtonRequestScope) {
        guard var state = states[scope],
            let index = state.waiters.firstIndex(where: { $0.id == id })
        else { return }
        let waiter = state.waiters.remove(at: index)
        states[scope] = state
        waiter.continuation.resume(throwing: CancellationError())
        drain(scope)
    }

    /// Time-based half of the recovery after a 429; see `Configuration.rateLimitRecoveryInterval`.
    private func recover(_ state: inout ScopeState, now timestamp: Date) {
        guard state.lastRecoveryAt != .distantPast, configuration.rateLimitRecoveryInterval > 0 else { return }
        let steps = Int(timestamp.timeIntervalSince(state.lastRecoveryAt) / configuration.rateLimitRecoveryInterval)
        guard steps > 0 else { return }
        for _ in 0..<min(steps, 16) {
            state.admissionInterval *= 0.5
            if state.admissionInterval < 0.01 { state.admissionInterval = 0 }
            if state.concurrencyLimit < state.initialConcurrency { state.concurrencyLimit += 1 }
        }
        if let lastAdmitted = state.admitted.last {
            state.nextAdmission = min(state.nextAdmission, lastAdmitted.addingTimeInterval(state.admissionInterval))
        }
        if state.admissionInterval == 0, state.concurrencyLimit >= state.initialConcurrency {
            state.lastRecoveryAt = .distantPast
        } else {
            state.lastRecoveryAt = state.lastRecoveryAt.addingTimeInterval(
                Double(steps) * configuration.rateLimitRecoveryInterval)
        }
    }

    private func drain(_ scope: ProtonRequestScope) {
        guard var state = states[scope] else { return }
        let timestamp = now()
        recover(&state, now: timestamp)

        while state.inFlight < state.concurrencyLimit, !state.waiters.isEmpty {
            guard !isAdmissionSuspended(scope) else {
                states[scope] = state
                return
            }
            let readyAt = max(state.cooldownUntil, state.nextAdmission)
            guard readyAt <= timestamp else {
                states[scope] = state
                scheduleWake(scope, at: readyAt)
                return
            }

            let index = bestWaiterIndex(in: state.waiters, now: timestamp)
            let waiter = state.waiters.remove(at: index)
            state.inFlight += 1
            state.activePermitIDs.insert(waiter.id)
            state.admitted.append(timestamp)
            state.nextAdmission = timestamp.addingTimeInterval(state.admissionInterval)
            tally.recordInFlight(state.inFlight, scope: scope)
            waiter.continuation.resume(
                returning: Permit(id: waiter.id, scope: scope, label: waiter.label, cause: waiter.cause))

            if state.admissionInterval > 0 {
                states[scope] = state
                scheduleWake(scope, at: state.nextAdmission)
                return
            }
        }

        states[scope] = state
        if state.waiters.isEmpty {
            wakeTasks[scope]?.cancel()
            wakeTasks[scope] = nil
        }
    }

    private func bestWaiterIndex(in waiters: [Waiter], now timestamp: Date) -> Int {
        waiters.indices.min { lhs, rhs in
            let left = effectivePriority(waiters[lhs], now: timestamp)
            let right = effectivePriority(waiters[rhs], now: timestamp)
            if left != right { return left < right }
            return waiters[lhs].sequence < waiters[rhs].sequence
        } ?? waiters.startIndex
    }

    private func effectivePriority(_ waiter: Waiter, now timestamp: Date) -> Int {
        guard waiter.priority != .immediate else { return 0 }
        let waited = max(0, timestamp.timeIntervalSince(waiter.enqueuedAt))
        let promotions = Int(waited / configuration.starvationPromotionInterval)
        return max(ProtonRequestPriority.userInitiated.rawValue, waiter.priority.rawValue - promotions)
    }

    private func scheduleWake(_ scope: ProtonRequestScope, at date: Date) {
        wakeTasks[scope]?.cancel()
        let delay = max(0, date.timeIntervalSince(now()))
        wakeTasks[scope] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.wake(scope)
        }
    }

    private func wake(_ scope: ProtonRequestScope) {
        wakeTasks[scope] = nil
        drain(scope)
    }

    private func prunePriorityScopes() {
        let timestamp = now()
        let before = priorityScopes.count
        priorityScopes = priorityScopes.filter { entry in
            guard let expiresAt = entry.value.expiresAt else { return true }
            return expiresAt > timestamp
        }
        if before != priorityScopes.count {
            drainAllScopes()
        }
    }

    private func isAdmissionSuspended(_ scope: ProtonRequestScope) -> Bool {
        return priorityScopes.values.contains { $0.suspendedScopes.contains(scope) }
    }

    private func drainAllScopes() {
        for scope in ProtonRequestScope.allCases {
            drain(scope)
        }
    }

    private func schedulePriorityWake() {
        priorityWakeTask?.cancel()
        guard let earliest = priorityScopes.values.compactMap({ $0.expiresAt }).min() else {
            priorityWakeTask = nil
            return
        }
        let delay = max(0, earliest.timeIntervalSince(now()))
        priorityWakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.priorityWake()
        }
    }

    private func priorityWake() {
        priorityWakeTask = nil
        prunePriorityScopes()
        schedulePriorityWake()
    }

    private static func prune(_ state: inout ScopeState, now: Date) {
        let cutoff = now.addingTimeInterval(-60)
        state.admitted.removeAll { $0 < cutoff }
        state.succeeded.removeAll { $0 < cutoff }
        state.rateLimited.removeAll { $0 < cutoff }
    }

    private static func countRecent(_ values: [Date], since cutoff: Date) -> Int {
        values.lazy.filter { $0 >= cutoff }.count
    }
}

enum ProtonRetryAfter {
    static func seconds(from response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        guard
            let value = response.value(forHTTPHeaderField: "Retry-After")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }

        for formatter in makeHTTPDateFormatters() {
            if let date = formatter.date(from: value) {
                return max(0, date.timeIntervalSince(now))
            }
        }
        return nil
    }

    private static func makeHTTPDateFormatters() -> [DateFormatter] {
        ["EEE',' dd MMM yyyy HH':'mm':'ss z", "EEEE',' dd-MMM-yy HH':'mm':'ss z", "EEE MMM d HH':'mm':'ss yyyy"].map {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = $0
            return formatter
        }
    }
}

extension ProtonRequestGovernor: RemoteRequestSupportSource {
    func remoteRequestSupportSnapshot() async -> RemoteRequestSupportSnapshot {
        requestSupportSnapshot()
    }
}
