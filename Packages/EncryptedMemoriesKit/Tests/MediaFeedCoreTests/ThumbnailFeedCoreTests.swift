import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import MediaDecodingCore
import Testing

@testable import MediaByteCache
@testable import MediaFeedCore
@testable import PhotosCore

private let feedCacheTestKey = SymmetricKey(size: .bits256)

@Test func decodePermitPoolDoesNotLeakCancelledWaiters() async throws {
    let pool = DecodePermitPool(permits: 1)
    #expect(await pool.acquire(priority: .idleLibraryCrawl))

    let waitingAcquire = Task { await pool.acquire(priority: .idleLibraryCrawl) }
    try await Task.sleep(for: .milliseconds(25))
    waitingAcquire.cancel()
    let cancelledAcquire = await waitingAcquire.value
    #expect(!cancelledAcquire)

    await pool.release()
    let replacementAcquire = await pool.acquire(priority: .visibleNow)
    #expect(replacementAcquire, "a cancelled viewport must not consume a decode lane")
    await pool.release()
}

@Test func latestVisibleDecodeDemandDropsOnlyPendingStaleWork() {
    let oldActive = LatestVisibleDecodeDemand.Job(
        uid: PhotoUID(volumeID: "vol", nodeID: "old-active"),
        maxPixels: 96,
        isUpgrade: false
    )
    let oldPending = LatestVisibleDecodeDemand.Job(
        uid: PhotoUID(volumeID: "vol", nodeID: "old-pending"),
        maxPixels: 96,
        isUpgrade: false
    )
    let latest = (0..<3).map {
        LatestVisibleDecodeDemand.Job(
            uid: PhotoUID(volumeID: "vol", nodeID: "latest-\($0)"),
            maxPixels: 96,
            isUpgrade: false
        )
    }
    var demand = LatestVisibleDecodeDemand()

    let acceptedOld = demand.replace(with: [oldActive, oldPending], generation: 1)
    let startedOld = demand.takeNext()
    let acceptedLatest = demand.replace(with: latest, generation: 2)
    #expect(acceptedOld)
    #expect(startedOld == oldActive)
    #expect(acceptedLatest)
    #expect(demand.pendingCount == latest.count)
    let startedLatest = demand.takeNext()
    let acceptedLateOld = demand.replace(with: [oldPending], generation: 1)
    #expect(startedLatest == latest[0])
    #expect(!acceptedLateOld)
    #expect(demand.generation == 2)
}

@Test func latestVisibleDecodeDemandSerializesSharperUpgradeForActiveAsset() {
    let uid = PhotoUID(volumeID: "vol", nodeID: "same-visible-asset")
    let small = LatestVisibleDecodeDemand.Job(uid: uid, maxPixels: 96, isUpgrade: false)
    let large = LatestVisibleDecodeDemand.Job(uid: uid, maxPixels: 384, isUpgrade: false)
    var demand = LatestVisibleDecodeDemand()

    let acceptedSmall = demand.replace(with: [small], generation: 1)
    #expect(acceptedSmall)
    #expect(demand.takeNext() == small)
    let acceptedLarge = demand.replace(with: [large], generation: 2)
    #expect(acceptedLarge)
    #expect(demand.pendingCount == 0, "an active decode must not be duplicated")

    demand.complete(small)
    let queuedUpgrade = demand.takeNext()
    #expect(queuedUpgrade?.uid == uid)
    #expect(queuedUpgrade?.maxPixels == large.maxPixels)
    #expect(queuedUpgrade?.isUpgrade == true)
}

@Test func latestVisibleDecodeDemandReturnsCancelledActiveJobToLatestViewport() {
    let old = LatestVisibleDecodeDemand.Job(
        uid: PhotoUID(volumeID: "vol", nodeID: "cancelled-visible-asset"),
        maxPixels: 96,
        isUpgrade: false
    )
    let replacement = LatestVisibleDecodeDemand.Job(
        uid: old.uid,
        maxPixels: 192,
        isUpgrade: false
    )
    var demand = LatestVisibleDecodeDemand()

    let acceptedOld = demand.replace(with: [old], generation: 1)
    #expect(acceptedOld)
    #expect(demand.takeNext() == old)
    let acceptedReplacement = demand.replace(with: [replacement], generation: 2)
    #expect(acceptedReplacement)
    demand.returnToPending(old)

    #expect(demand.activeCount == 0)
    #expect(demand.pendingCount == 1)
    #expect(demand.takeNext() == replacement, "cancellation must not lose the latest visible request")
}

@Test func latestVisibleDecodeDemandRealisticViewportMeasurement() {
    let jobs = (0..<512).map {
        LatestVisibleDecodeDemand.Job(
            uid: PhotoUID(volumeID: "vol", nodeID: "viewport-\($0)"),
            maxPixels: 384,
            isUpgrade: false
        )
    }
    var demand = LatestVisibleDecodeDemand()
    let started = ContinuousClock.now

    for generation in 1...240 {
        let accepted = demand.replace(with: jobs, generation: UInt64(generation))
        #expect(accepted)
    }
    let replacementElapsed = started.duration(to: ContinuousClock.now)
    #expect(demand.pendingCount == jobs.count)

    let drainStarted = ContinuousClock.now
    var drained = 0
    while let job = demand.takeNext() {
        demand.complete(job)
        drained += 1
    }
    let drainElapsed = drainStarted.duration(to: ContinuousClock.now)
    print(
        "[LatestVisibleDecodeDemand] viewport=\(jobs.count) replacements=240 "
            + "replaceElapsed=\(replacementElapsed) drainElapsed=\(drainElapsed)"
    )
    #expect(drained == jobs.count)
    #expect(demand.pendingCount == 0)
}

@Test func latestVisibleDecodeDemandInboxCoalescesQueuedGenerations() {
    let inbox = LatestVisibleDecodeDemandInbox()
    let first = [ThumbnailRequest(uid: PhotoUID(volumeID: "vol", nodeID: "first"), pixelSize: 96)]
    let latest = [ThumbnailRequest(uid: PhotoUID(volumeID: "vol", nodeID: "latest"), pixelSize: 192)]

    #expect(inbox.submit(requests: first), "the first producer owns drain scheduling")
    #expect(!inbox.submit(requests: latest), "later frames update the mailbox without more tasks")
    #expect(inbox.takeLatestOrFinish() == .init(requests: latest, generation: 2))
    #expect(inbox.takeLatestOrFinish() == nil, "an empty drain atomically releases ownership")
    #expect(inbox.submit(requests: first), "the next burst schedules exactly one new drain")
    #expect(
        inbox.takeLatestOrFinish() == .init(requests: first, generation: 3),
        "mailbox ordering must survive producer and data-source replacement")
}

@Test func latestVisibleDecodeDemandInboxOwnsMonotonicGeneration() {
    let inbox = LatestVisibleDecodeDemandInbox()
    let first = [ThumbnailRequest(uid: PhotoUID(volumeID: "vol", nodeID: "first"))]
    let replacement = [ThumbnailRequest(uid: PhotoUID(volumeID: "vol", nodeID: "replacement"))]

    #expect(inbox.submit(requests: first))
    #expect(inbox.takeLatestOrFinish() == .init(requests: first, generation: 1))
    #expect(inbox.takeLatestOrFinish() == nil)
    #expect(inbox.submit(requests: replacement))
    #expect(inbox.takeLatestOrFinish() == .init(requests: replacement, generation: 2))
}

@Test func latestVisibleDecodeDemandInboxReplayNeverSwallowsAFreshViewport() {
    let inbox = LatestVisibleDecodeDemandInbox()
    let viewport = [ThumbnailRequest(uid: PhotoUID(localPending: .photoLibrary, identifier: "asset"))]
    #expect(inbox.submit(requests: viewport))
    #expect(!inbox.replay(), "an undrained fresh viewport already carries its local demand")
    #expect(inbox.takeLatestOrFinish()?.isReplay == false)
    #expect(inbox.takeLatestOrFinish() == nil)

    inbox.invalidate()
    #expect(inbox.replay())
    #expect(inbox.takeLatestOrFinish()?.isReplay == true)
    #expect(inbox.takeLatestOrFinish() == nil)
    #expect(inbox.submit(requests: viewport), "a replay skips local demand, so the same viewport still gets through")
}

@Test func latestVisibleDecodeDemandInboxRetainsOnlyLatestIntentForReplay() {
    let inbox = LatestVisibleDecodeDemandInbox()
    let first = [ThumbnailRequest(uid: PhotoUID(volumeID: "vol", nodeID: "first"))]
    let latest = [ThumbnailRequest(uid: PhotoUID(volumeID: "vol", nodeID: "latest"))]
    #expect(inbox.submit(requests: first))
    _ = inbox.takeLatestOrFinish()
    #expect(inbox.takeLatestOrFinish() == nil)
    #expect(!inbox.submit(requests: first), "unchanged display ticks must not schedule more actor tasks")
    #expect(inbox.replay(), "a dependency change must retry even a drained viewport")
    #expect(!inbox.submit(requests: latest))
    #expect(inbox.takeLatestOrFinish()?.requests == latest, "recovery must not restore an older viewport")
    #expect(inbox.takeLatestOrFinish() == nil)
    #expect(inbox.submit(requests: []))
    _ = inbox.takeLatestOrFinish()
    #expect(inbox.takeLatestOrFinish() == nil)
    #expect(!inbox.replay(), "leaving the viewport removes recovery work")
    #expect(inbox.submit(requests: first))
    inbox.cancel()
    #expect(inbox.takeLatestOrFinish() == nil)
    #expect(!inbox.replay(), "shutdown must discard both queued and retained intent")
    #expect(inbox.submit(requests: first), "a fresh owner request can reuse the feed")
}

@Test func decodePermitPoolPrioritizesVisibleWaiters() async throws {
    let pool = DecodePermitPool(permits: 1)
    #expect(await pool.acquire(priority: .idleLibraryCrawl))
    let background = Task { await pool.acquire(priority: .idleLibraryCrawl) }
    let visible = Task { await pool.acquire(priority: .visibleNow) }
    try await Task.sleep(for: .milliseconds(25))

    await pool.release()
    #expect(await visible.value)
    await pool.release()
    #expect(await background.value)
    await pool.release()
}

@Test func thumbnailDecodeWorkExecutorLeavesCooperativeCaller() async {
    let executor = ThumbnailDecodeWorkExecutor()
    let ranOnMainThread = await executor.perform(priority: .visibleNow) { Thread.isMainThread }
    #expect(!ranOnMainThread)
}

private actor RecordingLoader: ThumbnailBatchLoader {
    private var order: [PhotoUID] = []
    private var finishedBatchCount = 0
    private let payloads: [PhotoUID: Data]
    private let itemErrors: [PhotoUID: String]
    private let batchError: String?
    private let failAll: Bool
    private let delayMilliseconds: Int
    /// Withheld on the first request, as after an authorization change during the download; delivered afterwards.
    private var withheldOnce: Set<PhotoUID>
    /// Refused on the first request, as for a node committed seconds ago; delivered afterwards.
    private var refusedOnce: [PhotoUID: String]

    init(
        payloads: [PhotoUID: Data] = [:],
        itemErrors: [PhotoUID: String] = [:],
        batchError: String? = nil,
        failAll: Bool = false,
        delayMilliseconds: Int = 0,
        withheldOnce: Set<PhotoUID> = [],
        refusedOnce: [PhotoUID: String] = [:]
    ) {
        self.payloads = payloads
        self.itemErrors = itemErrors
        self.batchError = batchError
        self.failAll = failAll
        self.delayMilliseconds = delayMilliseconds
        self.withheldOnce = withheldOnce
        self.refusedOnce = refusedOnce
    }

    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        order.append(contentsOf: uids)
        if delayMilliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
        }
        defer { finishedBatchCount += 1 }
        if let batchError { return ThumbnailBatchLoadResult(batchError: batchError) }
        guard !failAll else { return .delivered }  // models a loader that delivers nothing and reports nothing
        var errors: [PhotoUID: String] = [:]
        var withheld = Set<PhotoUID>()
        for uid in uids {
            if let reason = refusedOnce.removeValue(forKey: uid) {
                errors[uid] = reason
            } else if withheldOnce.remove(uid) != nil {
                withheld.insert(uid)
            } else if let data = payloads[uid] {
                onLoaded(uid, data)
            } else if let reason = itemErrors[uid] {
                errors[uid] = reason
            }
        }
        return ThumbnailBatchLoadResult(itemErrors: errors, withheldUIDs: withheld)
    }

    func fetched(_ uid: PhotoUID) -> Bool { order.contains(uid) }
    func requestOrder() -> [PhotoUID] { order }
    func requestCount() -> Int { order.count }
    func finishedBatches() -> Int { finishedBatchCount }
}

private actor CancellationAwareLoader: ThumbnailBatchLoader {
    private var requested: [PhotoUID] = []
    private var cancellationCount = 0
    private let delay: Duration

    init(delay: Duration) {
        self.delay = delay
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        requested.append(contentsOf: uids)
        do {
            try await Task.sleep(for: delay)
        } catch is CancellationError {
            cancellationCount += 1
        } catch {
            return ThumbnailBatchLoadResult(batchError: error.localizedDescription)
        }
        return .delivered
    }

    func requestCount() -> Int { requested.count }
    func cancellations() -> Int { cancellationCount }
}

private actor NonCooperativeLoader: ThumbnailBatchLoader {
    private var requested: [PhotoUID] = []
    private let delay: Duration

    init(delay: Duration) {
        self.delay = delay
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        requested.append(contentsOf: uids)
        let detachedDelay = Task.detached { [delay] in
            try? await Task.sleep(for: delay)
        }
        await detachedDelay.value
        return .delivered
    }

    func requestCount() -> Int { requested.count }
}

private actor ControlledLateLoader: ThumbnailBatchLoader {
    private let payloads: [PhotoUID: Data]
    private var requested: [PhotoUID] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var finishedBatchCount = 0

    init(payloads: [PhotoUID: Data]) {
        self.payloads = payloads
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        requested.append(contentsOf: uids)
        if !released {
            await withCheckedContinuation { continuation = $0 }
        }
        for uid in uids {
            if let data = payloads[uid] { onLoaded(uid, data) }
        }
        finishedBatchCount += 1
        return .delivered
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func requestCount() -> Int { requested.count }
    func requestedOrder() -> [PhotoUID] { requested }
    func finishedBatches() -> Int { finishedBatchCount }
    func isWaiting() -> Bool { continuation != nil }
}

private actor PerUIDControlledLateLoader: ThumbnailBatchLoader {
    private let payloads: [PhotoUID: Data]
    private var requested: [PhotoUID] = []
    private var continuations: [PhotoUID: [CheckedContinuation<Void, Never>]] = [:]
    private var released: Set<PhotoUID> = []
    private var finishedBatchCount = 0

    init(payloads: [PhotoUID: Data]) {
        self.payloads = payloads
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        requested.append(contentsOf: uids)
        for uid in uids where !released.contains(uid) {
            await withCheckedContinuation { continuation in
                continuations[uid, default: []].append(continuation)
            }
        }
        for uid in uids {
            if let data = payloads[uid] { onLoaded(uid, data) }
        }
        finishedBatchCount += 1
        return .delivered
    }

    func release(_ uid: PhotoUID) {
        released.insert(uid)
        let waiters = continuations.removeValue(forKey: uid) ?? []
        for waiter in waiters { waiter.resume() }
    }

    func requestCount() -> Int { requested.count }
    func finishedBatches() -> Int { finishedBatchCount }
}

private struct StubLocalThumbnails: LocalThumbnailLoading {
    let image: DecodedThumbnail
    var sizes: LocalRequestSizes?

    func thumbnails(for uids: [PhotoUID], maxPixelSize: CGFloat) async -> [PhotoUID: DecodedThumbnail] {
        await sizes?.record(maxPixelSize)
        return Dictionary(uniqueKeysWithValues: uids.map { ($0, image) })
    }
}

/// Answers once the test opens the gate.
private struct GatedLocalThumbnails: LocalThumbnailLoading {
    let image: DecodedThumbnail
    let gate: LocalGate

    func thumbnails(for uids: [PhotoUID], maxPixelSize: CGFloat) async -> [PhotoUID: DecodedThumbnail] {
        await gate.wait()
        return Dictionary(uniqueKeysWithValues: uids.map { ($0, image) })
    }
}

private actor LocalGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waiting = 0

    func wait() async {
        guard !isOpen else { return }
        waiting += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Never answers for `slow` until the request is cancelled; answers every other photo at once.
private struct SlowLocalThumbnails: LocalThumbnailLoading {
    let image: DecodedThumbnail
    let slow: PhotoUID
    let cancellations: LocalCancellations

    func thumbnails(for uids: [PhotoUID], maxPixelSize: CGFloat) async -> [PhotoUID: DecodedThumbnail] {
        if uids.contains(slow) {
            await cancellations.recordStart()
            try? await Task.sleep(for: .seconds(30))
            if Task.isCancelled { await cancellations.record() }
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: uids.map { ($0, image) })
    }
}

private actor LocalCancellations {
    private(set) var count = 0
    private(set) var starts = 0
    func record() { count += 1 }
    func recordStart() { starts += 1 }
}

private actor LocalRequestSizes {
    private(set) var values: [CGFloat] = []
    func record(_ size: CGFloat) { values.append(size) }
}

private actor PriorityRecordingLoader: PriorityThumbnailBatchLoader {
    private let payload: Data
    private let beforePriorityLoad: @Sendable (Int) async -> Void
    private var priorities: [ThumbnailPriority] = []

    /// `beforePriorityLoad` can hold the load with the given index.
    init(payload: Data, beforePriorityLoad: @escaping @Sendable (Int) async -> Void = { _ in }) {
        self.payload = payload
        self.beforePriorityLoad = beforePriorityLoad
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        for uid in uids { onLoaded(uid, payload) }
        return .delivered
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        priority: ThumbnailPriority,
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        let index = priorities.count
        priorities.append(priority)
        await beforePriorityLoad(index)
        for uid in uids { onLoaded(uid, payload) }
        return .delivered
    }

    var recordedPriorities: [ThumbnailPriority] { priorities }
}

/// Advanceable monotonic clock for deterministic demand-window tests (no real sleeps / wall-clock reliance).
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    func read() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Thread-safe fire counter for the `onImagesAvailable` arrival-wake tests (the callback is `@Sendable`).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    func value() -> Int { lock.withLock { count } }
}

private final class BlockingCoverageStore: ThumbnailCoverageCheckpointStore, @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false
    let release = DispatchSemaphore(value: 0)

    func loadPresent(_ candidates: [PhotoUID], for key: String) -> Set<PhotoUID> {
        lock.withLock { didEnter = true }
        release.wait()
        return []
    }

    var hasEntered: Bool { lock.withLock { didEnter } }

    func recordPresent(_ uids: [PhotoUID], for key: String) {}
    func recordMissing(_ uids: [PhotoUID], for key: String) {}
}

/// The two conditions that hold the crawl.
enum CrawlHold: String, CaseIterable, Sendable {
    case appSuspended
    case storageNearlyFull

    func begin(in state: LibraryRuntimeState) {
        switch self {
        case .appSuspended: state.update { $0.executionOpportunity = .suspended }
        case .storageNearlyFull: state.update { $0.storagePressure = .critical }
        }
    }

    func end(in state: LibraryRuntimeState) {
        switch self {
        case .appSuspended: state.update { $0.executionOpportunity = .foregroundActive }
        case .storageNearlyFull: state.update { $0.storagePressure = .normal }
        }
    }
}

/// Records how many batches load at the same time; `beforeLoad` can hold a batch.
private actor ConcurrencyRecordingLoader: ThumbnailBatchLoader {
    private let payload: Data
    private let beforeLoad: @Sendable (Int) async -> Void
    private var active = 0
    private(set) var peakConcurrentLoads = 0
    private(set) var loadedCount = 0
    private(set) var startedCount = 0

    init(payload: Data, beforeLoad: @escaping @Sendable (Int) async -> Void = { _ in }) {
        self.payload = payload
        self.beforeLoad = beforeLoad
    }

    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        let index = startedCount
        startedCount += 1
        active += 1
        peakConcurrentLoads = max(peakConcurrentLoads, active)
        await beforeLoad(index)
        active -= 1
        for uid in uids { onLoaded(uid, payload) }
        loadedCount += uids.count
        return .delivered
    }
}

/// Delivers the first batch and downloads every later batch until it is cancelled.
private actor FirstBatchThenHangingLoader: ThumbnailBatchLoader {
    private let payload: Data
    private(set) var requests: [PhotoUID] = []

    init(payload: Data) { self.payload = payload }

    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        let first = requests.isEmpty
        requests.append(contentsOf: uids)
        guard first else {
            try? await Task.sleep(for: .seconds(300))
            return .delivered
        }
        for uid in uids { onLoaded(uid, payload) }
        return .delivered
    }
}

/// A loader whose gated calls wait, ignoring cancellation, until the test opens their gate; it counts the loads that
/// have not returned.
private actor GatedLoader: ThumbnailBatchLoader {
    private let payload: Data
    private let gatedCalls: Set<Int>
    private let onCall: @Sendable (Int, [PhotoUID]) -> Void
    private var gates: [Int: OneShotGate] = [:]
    private(set) var calls: [PhotoUID] = []
    private var outstanding = 0
    private(set) var peakOutstanding = 0

    /// `onCall` runs when a load starts.
    init(
        payload: Data, gatedCalls: Set<Int>, onCall: @escaping @Sendable (Int, [PhotoUID]) -> Void = { _, _ in }
    ) {
        self.payload = payload
        self.gatedCalls = gatedCalls
        self.onCall = onCall
    }

    private func gate(_ index: Int) -> OneShotGate {
        if let gate = gates[index] { return gate }
        let gate = OneShotGate()
        gates[index] = gate
        return gate
    }

    func open(_ index: Int) async { await gate(index).open() }

    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        let index = calls.count
        calls.append(contentsOf: uids)
        onCall(index, uids)
        outstanding += 1
        peakOutstanding = max(peakOutstanding, outstanding)
        if gatedCalls.contains(index) {
            let gate = gate(index)
            await Task.detached { await gate.wait(limit: .seconds(60)) }.value
        }
        outstanding -= 1
        for uid in uids { onLoaded(uid, payload) }
        return .delivered
    }
}

/// The order of crawl batches and other work.
private actor EventOrder {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}

/// Opens once; waiters before and after the opening return. A wait that reaches its limit records an issue and
/// returns false, so a test never hangs on it.
private actor OneShotGate {
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    @discardableResult
    func wait(limit: Duration = .seconds(20), sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        guard !isOpen else { return true }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: limit)
            await self?.expire(id)
        }
        let opened = await withCheckedContinuation { waiters[id] = $0 }
        timer.cancel()
        if !opened { Issue.record("the gate did not open within \(limit)", sourceLocation: sourceLocation) }
        return opened
    }

    private func expire(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: false)
    }

    func open() {
        isOpen = true
        waiters.values.forEach { $0.resume(returning: true) }
        waiters.removeAll()
    }
}

private final class ValueBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? { lock.withLock { stored } }
    func set(_ value: T) { lock.withLock { stored = value } }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

/// Records each batch as "crawl <index>" before it loads; `beforeLoad` can hold a batch.
private actor OrderRecordingLoader: ThumbnailBatchLoader {
    private let payload: Data
    private let events: EventOrder
    private let beforeLoad: @Sendable (Int) async -> Void
    private var batches = 0

    init(payload: Data, events: EventOrder, beforeLoad: @escaping @Sendable (Int) async -> Void) {
        self.payload = payload
        self.events = events
        self.beforeLoad = beforeLoad
    }

    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        let index = batches
        batches += 1
        await events.append("crawl \(index)")
        await beforeLoad(index)
        for uid in uids { onLoaded(uid, payload) }
        return .delivered
    }
}

/// True for the first call only.
private final class FirstCall: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false

    func take() -> Bool {
        lock.withLock {
            defer { called = true }
            return !called
        }
    }
}

/// Withholds each photo on its first request, as after an authorization change, and calls `onWithheld` before it
/// answers; delivers the photo afterwards.
private actor WithheldOnceLoader: ThumbnailBatchLoader {
    private let payload: Data
    private let onWithheld: @Sendable () -> Void
    private var counts: [PhotoUID: Int] = [:]

    init(payload: Data, onWithheld: @escaping @Sendable () -> Void) {
        self.payload = payload
        self.onWithheld = onWithheld
    }

    func loadThumbnails(
        for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        var withheld = Set<PhotoUID>()
        for uid in uids {
            counts[uid, default: 0] += 1
            if counts[uid] == 1 { withheld.insert(uid) } else { onLoaded(uid, payload) }
        }
        if !withheld.isEmpty { onWithheld() }
        return ThumbnailBatchLoadResult(itemErrors: [:], withheldUIDs: withheld)
    }

    func requests(for uid: PhotoUID) -> Int { counts[uid] ?? 0 }
}

private final class BlockingDiskProbeHook: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var exited = false
    let release = DispatchSemaphore(value: 0)

    func wait() {
        lock.withLock { entered = true }
        release.wait()
        lock.withLock { exited = true }
    }

    var hasEntered: Bool { lock.withLock { entered } }
    var hasExited: Bool { lock.withLock { exited } }
}

private final class RecordingCoverageStore: ThumbnailCoverageCheckpointStore, @unchecked Sendable {
    private let lock = NSLock()
    private var present: Set<PhotoUID> = []
    private var presentWrites = 0

    func loadPresent(_ candidates: [PhotoUID], for key: String) -> Set<PhotoUID> {
        lock.withLock { present.intersection(candidates) }
    }

    func recordPresent(_ uids: [PhotoUID], for key: String) {
        guard !uids.isEmpty else { return }
        lock.withLock {
            present.formUnion(uids)
            presentWrites += 1
        }
    }

    func recordMissing(_ uids: [PhotoUID], for key: String) {
        lock.withLock { present.subtract(uids) }
    }

    var snapshot: Set<PhotoUID> { lock.withLock { present } }
    var writeCount: Int { lock.withLock { presentWrites } }
}

@Suite("MediaFeedCore")
struct ThumbnailFeedCoreTests {
    @Test func directVisibleFetchUsesPriorityAwareLoader() async throws {
        let uid = Self.uid("priority-visible")
        let loader = PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24))
        let feed = ThumbnailFeedCore(
            cache: Self.cache("priority-visible"),
            loader: loader,
            configuration: Self.configuration()
        )

        #expect(await feed.decoded(for: uid) != nil)
        #expect(await loader.recordedPriorities == [.visibleNow])
    }

    @Test func visibleDecodedLoadsTheShownThumbnailIntoTheSharedDecodedTier() async throws {
        let uid = Self.uid("visible-decoded")
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 24, height: 24)], delayMilliseconds: 0)
        let feed = ThumbnailFeedCore(
            cache: Self.cache("visible-decoded"), loader: loader, configuration: Self.configuration())

        #expect(await feed.visibleDecoded(for: uid) != nil)
        #expect(feed.memoryDecoded(for: uid) != nil, "the image stays in the bounded decoded tier, not in a view")
    }

    @Test func duplicateCachedOutsideTheLibraryScopeAppears() async throws {
        let listed = Self.uid("duplicates-listed")
        let duplicate = Self.uid("duplicates-outside-scope")
        let cache = Self.cache("duplicates-outside-scope")
        let loader = RecordingLoader()
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration())
        await feed.setPrefetchEnabled(false)
        cache.storeToDisk(Self.pngData(width: 24, height: 24), for: duplicate)
        #expect(cache.diskData(for: duplicate) != nil, "a blank tile is backed by an encrypted disk thumbnail")
        let graph = LibrarySourceGraph()
        let source = LibrarySource(id: SourceID("duplicates-cached-library"), capabilities: .readThumbnail)
        _ = graph.commitSourceSet([source], using: graph.beginSourceSetRefresh())
        let change = try #require(graph.installCachedInventory(Self.sourceItems([listed]), for: source.id))
        #expect(await feed.bindDerivedDataEpoch(graph.runtimeEpoch))
        _ = await feed.reconcile(
            selected: change.selectedScope, analysis: change.analysisScope,
            retention: change.thumbnailRetentionScope)
        #expect(cache.diskFileCount() == 1, "partial inventory must keep the encrypted thumbnail")
        #expect(!change.thumbnailRetentionScope.uids.contains(duplicate))
        #expect(await feed.requestPriority(duplicate) == false, "the library grid must stay fail-closed")
        #expect(await feed.decoded(for: duplicate) == nil, "without an access the tile stays blank (#439)")
        let access = feed.beginVisibleThumbnailAccess(for: duplicate)
        defer { access.end() }
        let tile = Task { await feed.visibleDecoded(for: duplicate, access: access) }
        // The deadline is only a guard against a hang: a loaded runner cannot promise a speed.
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, feed.memoryDecoded(for: duplicate, access: access) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            feed.memoryDecoded(for: duplicate, access: access) != nil,
            "the visible duplicate must show its cached thumbnail")
        tile.cancel()
        _ = await tile.value
        #expect(await loader.requestCount() == 0, "cached tiles need no network request")
        #expect(feed.memoryDecoded(for: duplicate) == nil, "the grant never widens the library grid's read")
        let other = feed.beginVisibleThumbnailAccess(for: listed)
        #expect(feed.memoryDecoded(for: duplicate, access: other) == nil, "an access reads only its own photo")
        other.end()
        #expect(feed.openVisibleThumbnailAccessUIDs == [duplicate])
        access.end()
        #expect(feed.memoryDecoded(for: duplicate, access: access) == nil, "the tile left the screen")
        #expect(await feed.cachedDecoded(for: duplicate, access: access) == nil)
        #expect(feed.openVisibleThumbnailAccessUIDs.isEmpty)
        await feed.stopPrefetchAndWait()
    }

    @Test func adoptedPhotoOutsideTheCacheScopeKeepsTheCacheReadCheck() async throws {
        let local = PhotoUID(localPending: .photoLibrary, identifier: "asset-cache-scope")
        let remote = Self.uid("adopted-outside-cache-scope")
        let listed = Self.uid("adopted-cache-scope-listed")
        let cache = Self.cache("adopted-outside-cache-scope")
        cache.storeToDisk(Self.pngData(width: 24, height: 24), for: remote)
        let feed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(), configuration: Self.configuration())
        await feed.setPrefetchEnabled(false)
        let graph = LibrarySourceGraph()
        let source = LibrarySource(id: SourceID("adopted-cache-scope"), capabilities: .readThumbnail)
        _ = graph.commitSourceSet([source], using: graph.beginSourceSetRefresh())
        let change = try #require(graph.installCachedInventory(Self.sourceItems([listed]), for: source.id))
        #expect(await feed.bindDerivedDataEpoch(graph.runtimeEpoch))
        _ = await feed.reconcile(
            selected: change.selectedScope, analysis: change.analysisScope,
            retention: change.thumbnailRetentionScope)
        #expect(cache.diskFileCount() == 1)
        await feed.setLocalThumbnailLoader(StubLocalThumbnails(image: Self.decodedThumb(16, 16)))
        await feed.setLocalAuthorization([local])
        _ = await feed.decoded(for: local)
        #expect(await feed.adoptDecoded(from: local, to: remote), "the feed authorizes the adopted photo")
        feed.applyDecodedMemoryPressure(scale: 1, purge: true)
        #expect(feed.memoryDecoded(for: remote) == nil)
        #expect(
            await feed.cachedDecoded(for: remote) == nil,
            "a grid read without an access keeps the cache's own retention check")
        await feed.stopPrefetchAndWait()
    }

    @Test func visibleThumbnailAccessEndsWithTheFeedStopAndTheCacheClear() async throws {
        let duplicate = Self.uid("duplicates-access-fences")
        let cache = Self.cache("duplicates-access-fences")
        cache.storeToDisk(Self.pngData(width: 24, height: 24), for: duplicate)
        let feed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(), configuration: Self.configuration())
        await feed.setPrefetchEnabled(false)
        let stopped = feed.beginVisibleThumbnailAccess(for: duplicate)
        #expect(await feed.cachedDecoded(for: duplicate, access: stopped) != nil)
        await feed.stopPrefetchAndWait()
        #expect(feed.memoryDecoded(for: duplicate, access: stopped) == nil, "a feed stop revokes every access")
        #expect(await feed.cachedDecoded(for: duplicate, access: stopped) == nil)

        let cleared = feed.beginVisibleThumbnailAccess(for: duplicate)
        #expect(await feed.cachedDecoded(for: duplicate, access: cleared) != nil)
        await cache.clear()
        #expect(feed.memoryDecoded(for: duplicate, access: cleared) == nil, "a cache clear revokes every access")
        #expect(await feed.cachedDecoded(for: duplicate, access: cleared) == nil)
        stopped.end()
        cleared.end()
        #expect(feed.openVisibleThumbnailAccessUIDs.isEmpty)
    }

    @MainActor @Test func visibleThumbnailSessionKeepsAccessOnlyForTheShownPhoto() async throws {
        let first = Self.uid("duplicates-session-first")
        let second = Self.uid("duplicates-session-second")
        let cache = Self.cache("duplicates-session")
        cache.storeToDisk(Self.pngData(width: 24, height: 24), for: first)
        cache.storeToDisk(Self.pngData(width: 24, height: 24), for: second)
        let feed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(), configuration: Self.configuration())
        await feed.setPrefetchEnabled(false)
        let session = VisibleThumbnailSession(feed: feed)
        session.select(first)
        #expect(await session.cachedDecoded(for: first) != nil, "the shown copy reads its cached thumbnail")
        #expect(await session.cachedDecoded(for: second) == nil, "a copy that is not shown has no access")
        session.select(second)
        #expect(feed.openVisibleThumbnailAccessUIDs == [second], "a new selection revokes the previous copy")
        #expect(session.memoryDecoded(for: first) == nil)
        #expect(await session.visibleDecoded(for: second) != nil)
        session.end()
        #expect(feed.openVisibleThumbnailAccessUIDs.isEmpty, "closing the viewer revokes its access")
        #expect(session.memoryDecoded(for: second) == nil)
        await feed.stopPrefetchAndWait()
    }

    /// A viewer that appears again opens the access of its photo only when it is not open: a load that holds the open
    /// access finishes, and an access that a cover ended opens again.
    @MainActor @Test func visibleThumbnailSessionReopensOnlyAClosedAccess() async throws {
        let uid = Self.uid("duplicates-session-reopen")
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 24, height: 24)], delayMilliseconds: 300)
        let feed = ThumbnailFeedCore(
            cache: Self.cache("duplicates-session-reopen"), loader: loader, configuration: Self.configuration())
        let session = VisibleThumbnailSession(feed: feed)
        session.select(uid)
        let load = Task { await session.visibleDecoded(for: uid) }
        for _ in 0..<200 where await loader.requestCount() == 0 { try await Task.sleep(for: .milliseconds(5)) }

        session.reopen(uid)

        #expect(await load.value != nil, "the open access stays, so its load finishes")
        #expect(feed.openVisibleThumbnailAccessUIDs == [uid])
        session.end()
        #expect(feed.openVisibleThumbnailAccessUIDs.isEmpty)
        session.reopen(uid)
        #expect(feed.openVisibleThumbnailAccessUIDs == [uid], "an ended access opens again")
        session.end()
        await feed.stopPrefetchAndWait()
    }

    @Test func cachedDuplicateSurvivesLibraryViewportReplacement() async throws {
        let duplicate = Self.uid("duplicates-viewport")
        let cache = Self.cache("duplicates-viewport")
        cache.storeToDisk(Self.pngData(width: 24, height: 24), for: duplicate)
        let loader = RecordingLoader()
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration())
        await feed.setPrefetchEnabled(false)
        #expect(await feed.requestPriority(duplicate))
        _ = await feed.replaceVisiblePriorityDemand([])
        #expect(await feed.prefetchStatus().currentQueueLength == 0, "the grid drops unowned visible priority")
        let tile = Task { await feed.visibleDecoded(for: duplicate) }
        // The deadline is only a guard against a hang: a loaded runner cannot promise a speed.
        let deadline = ContinuousClock.now + .seconds(10)
        while feed.memoryDecoded(for: duplicate) == nil, ContinuousClock.now < deadline {
            _ = await feed.replaceVisiblePriorityDemand([])
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(feed.memoryDecoded(for: duplicate) != nil, "direct disk decode does not depend on the queue")
        tile.cancel()
        _ = await tile.value
        #expect(await loader.requestCount() == 0)
        await feed.stopPrefetchAndWait()
    }

    @Test func visibleDecodedStopsWithoutAnImageWhenTheViewLeaves() async throws {
        let uid = Self.uid("visible-decoded-cancel")
        let loader = RecordingLoader(payloads: [:], delayMilliseconds: 0)
        let feed = ThumbnailFeedCore(
            cache: Self.cache("visible-decoded-cancel"), loader: loader, configuration: Self.configuration())
        let load = Task { await feed.visibleDecoded(for: uid) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now

        load.cancel()

        #expect(await load.value == nil)
        #expect(start.duration(to: .now) < .milliseconds(500), "the backoff ends with the view")
    }

    @Test func concurrentDirectRequestsForSameUIDShareOneLoaderCall() async throws {
        let uid = Self.uid("direct-coalesced")
        let loader = RecordingLoader(
            payloads: [uid: Self.pngData(width: 24, height: 24)],
            delayMilliseconds: 25
        )
        let feed = ThumbnailFeedCore(
            cache: Self.cache("direct-coalesced"),
            loader: loader,
            configuration: Self.configuration()
        )

        async let first = feed.decoded(for: uid)
        async let second = feed.decoded(for: uid)

        #expect(await first != nil)
        #expect(await second != nil)
        #expect(await loader.requestCount() == 1)
    }

    @Test func aDirectLoadOfAPhotoInADownloadingBatchIsCountedAndNeverHeldBack() async throws {
        let inBatch = Self.uid("overlap-in-batch")
        let other = Self.uid("overlap-other")
        let payload = Self.pngData(width: 24, height: 24)
        let diagnostics = PhotoDiagnostics()
        let loader = PerUIDControlledLateLoader(payloads: [inBatch: payload, other: payload])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("overlap"),
            loader: loader,
            configuration: Self.configuration(
                downloadConcurrencyLimit: 1,
                batchSize: 1,
                downloadTimeoutSeconds: 30
            ),
            diagnostics: diagnostics
        )
        defer {
            Task {
                await loader.release(inBatch)
                await loader.release(other)
            }
        }
        let key = "thumb.directLoadOverlapsBatch"

        #expect(await feed.requestPriority(inBatch))
        try await Self.waitUntil { await loader.requestCount() == 1 }
        #expect(await loader.requestCount() == 1, "the batch is downloading")

        let elsewhere = Task { await feed.decoded(for: other) }
        try await Self.waitUntil { await loader.requestCount() == 2 }
        #expect(await loader.requestCount() == 2)
        #expect(diagnostics.counter(key) == 0, "a photo outside the batch is no overlap")

        let overlapping = Task { await feed.decoded(for: inBatch) }
        try await Self.waitUntil { await loader.requestCount() == 3 }
        #expect(await loader.requestCount() == 3, "the direct load does not wait for the batch")
        #expect(diagnostics.counter(key) == 1)

        await feed.stopPrefetch()
        let afterStop = Task { await feed.decoded(for: inBatch) }
        try await Self.waitUntil { await loader.requestCount() == 4 }
        #expect(await loader.requestCount() == 4)
        #expect(diagnostics.counter(key) == 1, "a stopped feed forgets its batches")

        await loader.release(inBatch)
        await loader.release(other)
        #expect(await elsewhere.value != nil)
        #expect(await overlapping.value != nil)
        #expect(await afterStop.value != nil)
        await feed.stopPrefetchAndWait()
    }

    @Test func everyVisibleWarmPassUsesHighestPriority() async throws {
        let first = Self.uid("visible-warm-first")
        let later = Self.uid("visible-warm-later")
        let loader = PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24))
        let feed = ThumbnailFeedCore(
            cache: Self.cache("visible-warm-priority"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        _ = await feed.warmVisibleDecoded([ThumbnailRequest(uid: first)], limit: 1)
        try await Self.waitUntil { await loader.recordedPriorities.count == 1 }
        _ = await feed.warmVisibleDecoded([ThumbnailRequest(uid: later)], limit: 1)
        try await Self.waitUntil { await loader.recordedPriorities.count == 2 }

        #expect(await loader.recordedPriorities == [.visibleNow, .visibleNow])
    }

    @Test func visibleArrivalsStayInMemoryWhenTheDeviceIsNearlyFull() async throws {
        let uid = Self.uid("visible-storage-critical")
        let loader = PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24))
        let nearlyFull = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(storagePressure: .critical))
        let feed = ThumbnailFeedCore(
            cache: Self.cache("visible-storage-critical", runtimeState: nearlyFull),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        let warm = await feed.warmVisibleDecoded([ThumbnailRequest(uid: uid)], limit: 1)
        #expect(warm.queuedNetwork == 1)
        try await Self.waitUntil { await feed.cachedDecoded(for: uid) != nil }
        #expect(await loader.recordedPriorities == [.visibleNow])
    }

    @Test func crawlSleepsWhileTheDeviceIsNearlyFullAndResumesWhenStorageRecovers() async throws {
        let crawled = [Self.uid("storage-crawl-a"), Self.uid("storage-crawl-b")]
        let visible = Self.uid("storage-crawl-visible")
        let loader = PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24))
        let runtimeState = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(storagePressure: .critical))
        let feed = ThumbnailFeedCore(
            cache: Self.cache("storage-critical-crawl", runtimeState: runtimeState),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 2, batchSize: 1)
        )
        await feed.startPrefetch(crawled)

        let stopped = Counter()
        let waiter = Task {
            try await feed.waitForPrefetchToFinish()
            stopped.increment()
        }
        try await Self.waitUntil { stopped.value() == 1 }
        #expect(stopped.value() == 1, "the crawl workers stop instead of polling")
        waiter.cancel()
        _ = try? await waiter.value
        #expect(await feed.hasPendingThumbnailWork())
        #expect(await loader.recordedPriorities.isEmpty)

        _ = await feed.requestPriority(visible)
        try await Self.waitUntil { await loader.recordedPriorities.count == 1 }
        #expect(await loader.recordedPriorities == [.visibleNow], "visible photos still load")

        runtimeState.update { $0.storagePressure = .normal }
        try await Self.waitUntil { await loader.recordedPriorities.count == 3 }
        #expect(await loader.recordedPriorities == [.visibleNow, .idleLibraryCrawl, .idleLibraryCrawl])
        await feed.stopPrefetchAndWait()
    }

    /// A coordinator of its own per test, which follows the runtime state as the app's shared one does.
    private static func coordinator(_ state: LibraryRuntimeState) async -> LibraryResourceCoordinator {
        let coordinator = LibraryResourceCoordinator(runtimeState: state)
        await coordinator.startObserving()
        return coordinator
    }

    @Test func crawlLoadsInABackgroundWindowOneBatchAtATimeUnderThePermit() async throws {
        let crawled = (0..<3).map { Self.uid("window-crawl-\($0)") }
        let firstBatch = OneShotGate()
        let loader = ConcurrencyRecordingLoader(payload: Self.pngData(width: 24, height: 24)) { index in
            if index == 0 { await firstBatch.wait() }
        }
        // The backup window of iOS runs the app in the background.
        let runtimeState = LibraryRuntimeState(
            initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted))
        let coordinator = await Self.coordinator(runtimeState)
        // Two downloaders from the start: only the permit can keep the second batch out.
        let feed = ThumbnailFeedCore(
            cache: Self.cache("window-crawl", runtimeState: runtimeState),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 2, initialDownloadConcurrency: 2, batchSize: 1),
            resourceCoordinator: coordinator
        )
        await feed.startPrefetch(crawled)

        try await Self.waitUntil { await loader.startedCount == 1 }
        try await Self.waitUntil { await coordinator.waitingPermitCount == 1 }
        #expect(await coordinator.waitingPermitCount == 1, "the second worker waits for the permit, not for a slot")
        #expect(await loader.startedCount == 1)
        await firstBatch.open()

        try await Self.waitUntil { await loader.loadedCount == 3 }
        #expect(await loader.loadedCount == 3, "the crawl loads in the background window")
        #expect(await loader.peakConcurrentLoads == 1, "one batch at a time under the single permit")
        #expect(await coordinator.metrics().permitsAcquired >= 3, "every batch took the permit")
        await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
    }

    @Test func crawlSleepsWhileTheAppIsSuspended() async throws {
        let crawled = [Self.uid("suspended-crawl-a"), Self.uid("suspended-crawl-b")]
        let loader = PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24))
        let runtimeState = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(executionOpportunity: .suspended))
        let feed = ThumbnailFeedCore(
            cache: Self.cache("suspended-crawl", runtimeState: runtimeState),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 2, batchSize: 1)
        )
        await feed.startPrefetch(crawled)

        let stopped = Counter()
        let waiter = Task {
            try await feed.waitForPrefetchToFinish()
            stopped.increment()
        }
        try await Self.waitUntil { stopped.value() == 1 }
        waiter.cancel()
        await Self.join(Task { _ = try? await waiter.value }, "the waiter ends")
        // Nothing on screen asked for a photo, so only the hold keeps the crawl from loading.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await loader.recordedPriorities.isEmpty, "a suspended app loads nothing")

        runtimeState.update { $0.executionOpportunity = .foregroundActive }
        try await Self.waitUntil { await loader.recordedPriorities.count == 2 }
        #expect(await loader.recordedPriorities == [.idleLibraryCrawl, .idleLibraryCrawl])
        await feed.stopPrefetchAndWait()
    }

    @Test func lowPowerModeInABackgroundWindowKeepsTheCrawlWaitingWithoutPolling() async throws {
        let crawled = [Self.uid("low-power-crawl-a"), Self.uid("low-power-crawl-b")]
        let loader = PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24))
        let runtimeState = LibraryRuntimeState(
            initial: LibraryRuntimeSnapshot(isLowPowerMode: true, executionOpportunity: .backgroundPermitted))
        let coordinator = await Self.coordinator(runtimeState)
        let feed = ThumbnailFeedCore(
            cache: Self.cache("low-power-crawl", runtimeState: runtimeState),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 2, batchSize: 1),
            resourceCoordinator: coordinator
        )
        await feed.startPrefetch(crawled)
        // The workers wait in the coordinator's queue instead of polling.
        try await Self.waitUntil { await coordinator.waitingPermitCount == 2 }
        #expect(await coordinator.waitingPermitCount == 2)
        #expect(await loader.recordedPriorities.isEmpty, "Low Power Mode refuses the crawl in the background")

        // A photo on screen still loads, without the crawl's permit.
        let visible = Self.uid("low-power-crawl-visible")
        _ = await feed.requestPriority(visible)
        try await Self.waitUntil { await loader.recordedPriorities.count == 1 }
        #expect(await loader.recordedPriorities == [.visibleNow], "a photo on screen still loads")
        #expect(await coordinator.metrics().permitsAcquired == 0, "it took no permit")

        runtimeState.update { $0.isLowPowerMode = false }
        try await Self.waitUntil { await loader.recordedPriorities.count == 3 }
        #expect(await loader.recordedPriorities == [.visibleNow, .idleLibraryCrawl, .idleLibraryCrawl])
        await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
    }

    @Test func photosOnScreenLoadInALowPowerWindowWithoutAPermit() async throws {
        let firstLoad = OneShotGate()
        let firstLoadStarted = OneShotGate()
        let loader = PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24)) { index in
            guard index == 0 else { return }
            await firstLoadStarted.open()
            await firstLoad.wait()
        }
        let runtimeState = LibraryRuntimeState(
            initial: LibraryRuntimeSnapshot(isLowPowerMode: true, executionOpportunity: .backgroundPermitted))
        let coordinator = await Self.coordinator(runtimeState)
        // One worker: after the first photo, the second one is already queued when the worker asks again.
        let feed = ThumbnailFeedCore(
            cache: Self.cache("low-power-visible", runtimeState: runtimeState),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1),
            resourceCoordinator: coordinator
        )
        await feed.startPrefetch([Self.uid("low-power-visible-crawl")])
        try await Self.waitUntil { await coordinator.waitingPermitCount == 1 }

        _ = await feed.requestPriority(Self.uid("low-power-visible-a"))
        // The worker loads the first photo; the second one is queued before that load ends.
        await firstLoadStarted.wait()
        _ = await feed.requestPriority(Self.uid("low-power-visible-b"))
        await firstLoad.open()
        try await Self.waitUntil { await loader.recordedPriorities.count == 2 }
        #expect(await loader.recordedPriorities == [.visibleNow, .visibleNow], "both photos on screen load")
        #expect(await coordinator.metrics().permitsAcquired == 0, "without the crawl's permit")
        await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
    }

    @Test func aBackupItemTakesThePermitBeforeTheNextCrawlBatch() async throws {
        let crawled = [Self.uid("backup-first-a"), Self.uid("backup-first-b")]
        let events = EventOrder()
        let firstBatch = OneShotGate()
        let loader = OrderRecordingLoader(payload: Self.pngData(width: 24, height: 24), events: events) { index in
            if index == 0 { await firstBatch.wait() }
        }
        let runtimeState = LibraryRuntimeState(
            initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted))
        let coordinator = await Self.coordinator(runtimeState)
        let feed = ThumbnailFeedCore(
            cache: Self.cache("backup-first", runtimeState: runtimeState),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 2, batchSize: 1),
            resourceCoordinator: coordinator
        )
        await feed.startPrefetch(crawled)
        try await Self.waitUntil { await events.entries.count == 1 }
        // The second worker already waits for the permit; the backup item arrives after it but outranks it.
        try await Self.waitUntil { await coordinator.waitingPermitCount == 1 }
        let backup = Task {
            _ = try? await coordinator.withHeavyPermit(
                LibraryWorkRequest(workload: .backupHashing, intent: .automatic)
            ) { _ in await events.append("backup") }
        }
        try await Self.waitUntil { await coordinator.waitingPermitCount == 2 }
        await firstBatch.open()
        try await Self.waitUntil { await events.entries.count == 3 }
        #expect(await events.entries == ["crawl 0", "backup", "crawl 1"])
        await Self.join(backup, "the backup item ends")
        await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
    }

    @Test func theEndOfTheWindowEndsTheCrawlsWaitForThePermit() async throws {
        let crawled = [Self.uid("window-end-a"), Self.uid("window-end-b")]
        let loader = PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24))
        let runtimeState = LibraryRuntimeState(
            initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted))
        let coordinator = await Self.coordinator(runtimeState)
        let backupEntered = OneShotGate()
        let backupRelease = OneShotGate()
        let backup = Task {
            _ = try? await coordinator.withHeavyPermit(
                LibraryWorkRequest(workload: .backupHashing, intent: .automatic)
            ) { _ in
                await backupEntered.open()
                await backupRelease.wait()
            }
        }
        await backupEntered.wait()
        let feed = ThumbnailFeedCore(
            cache: Self.cache("window-end", runtimeState: runtimeState),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 2, batchSize: 1),
            resourceCoordinator: coordinator
        )
        await feed.startPrefetch(crawled)
        try await Self.waitUntil { await coordinator.waitingPermitCount == 2 }
        #expect(await coordinator.waitingPermitCount == 2, "both workers wait behind the backup item")

        // Back in the foreground the crawl runs as before, while the backup item still holds the permit.
        runtimeState.update { $0.executionOpportunity = .foregroundActive }
        try await Self.waitUntil { await loader.recordedPriorities.count == 2 }
        #expect(await loader.recordedPriorities.count == 2)
        try await Self.waitUntil { await coordinator.waitingPermitCount == 0 }
        #expect(await coordinator.waitingPermitCount == 0, "the coordinator keeps no waiter behind")
        await backupRelease.open()
        await Self.join(backup, "the backup item ends")
        await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
    }

    #if DEBUG
        @Test func aNewWindowAfterAnEndedWaitStillWaitsForThePermit() async throws {
            let crawled = [Self.uid("new-window-a"), Self.uid("new-window-b")]
            let loader = PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24))
            let runtimeState = LibraryRuntimeState(
                initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted))
            let coordinator = await Self.coordinator(runtimeState)
            let backupEntered = OneShotGate()
            let backupRelease = OneShotGate()
            let backup = Task {
                _ = try? await coordinator.withHeavyPermit(
                    LibraryWorkRequest(workload: .backupHashing, intent: .automatic)
                ) { _ in
                    await backupEntered.open()
                    await backupRelease.wait()
                }
            }
            await backupEntered.wait()
            let feed = ThumbnailFeedCore(
                cache: Self.cache("new-window", runtimeState: runtimeState),
                loader: loader,
                configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1),
                resourceCoordinator: coordinator
            )
            await feed.startPrefetch(crawled)
            try await Self.waitUntil { await coordinator.waitingPermitCount == 1 }

            // The foreground ends the wait; before the worker goes on, a new background window begins.
            let afterWait = BlockingDiskProbeHook()
            let first = FirstCall()
            feed.setWindowPermitWaitHookForTesting { if first.take() { afterWait.wait() } }
            defer {
                afterWait.release.signal()
                feed.setWindowPermitWaitHookForTesting(nil)
            }
            runtimeState.update { $0.executionOpportunity = .foregroundActive }
            try await Self.waitUntil { afterWait.hasEntered }
            runtimeState.update { $0.executionOpportunity = .backgroundPermitted }
            afterWait.release.signal()

            try await Self.waitUntil { await coordinator.waitingPermitCount == 1 }
            #expect(await coordinator.waitingPermitCount == 1, "the worker waits for the permit of the new window")
            #expect(await loader.recordedPriorities.isEmpty, "no batch beside the backup item")

            await backupRelease.open()
            try await Self.waitUntil { await loader.recordedPriorities.count == 2 }
            #expect(await loader.recordedPriorities.count == 2)
            await Self.join(backup, "the backup item ends")
            await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
        }

        @Test func aSessionChangeDuringTheCoverageRefreshReleasesThePermitAndEndsTheWorker() async throws {
            let uid = Self.uid("refresh-session-change")
            let runtimeState = LibraryRuntimeState(
                initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted))
            let coordinator = await Self.coordinator(runtimeState)
            let cache = Self.cache("refresh-session-change", runtimeState: runtimeState)
            // Nothing arrives, so the coverage stays incomplete and the end-of-crawl refresh scans the disk.
            let feed = ThumbnailFeedCore(
                cache: cache, loader: RecordingLoader(failAll: true),
                configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1),
                resourceCoordinator: coordinator
            )
            let step = BlockingDiskProbeHook()
            let first = FirstCall()
            feed.setCoverageScanStepHookForTesting { if first.take() { step.wait() } }
            defer {
                step.release.signal()
                feed.setCoverageScanStepHookForTesting(nil)
            }
            await feed.startPrefetch([uid])
            try await Self.waitUntil { step.hasEntered }

            // The account changes while the refresh holds the permit, and a backup item waits for it.
            cache.configure(accountUID: "acct-B", key: feedCacheTestKey)
            let backupEntered = OneShotGate()
            let backup = Task {
                _ = try? await coordinator.withHeavyPermit(
                    LibraryWorkRequest(workload: .backupHashing, intent: .automatic)
                ) { _ in await backupEntered.open() }
            }
            try await Self.waitUntil { await coordinator.waitingPermitCount == 1 }
            step.release.signal()

            #expect(await backupEntered.wait(), "the backup item gets the permit")
            try await Self.waitUntil { await !feed.downloadCountersForTesting().workersRunning }
            #expect(await !feed.downloadCountersForTesting().workersRunning, "the worker ends")
            await Self.join(backup, "the backup item ends")
            await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
        }

        @Test func aSessionChangeDuringTheCoverageRefreshEndsTheWorkerInTheForeground() async throws {
            // No permit and no waiting backup item: only the changed session can end the refresh.
            let uid = Self.uid("refresh-session-change-foreground")
            let cache = Self.cache("refresh-session-change-foreground")
            let feed = ThumbnailFeedCore(
                cache: cache, loader: RecordingLoader(failAll: true),
                configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
            )
            let step = BlockingDiskProbeHook()
            let first = FirstCall()
            feed.setCoverageScanStepHookForTesting { if first.take() { step.wait() } }
            defer {
                step.release.signal()
                feed.setCoverageScanStepHookForTesting(nil)
            }
            await feed.startPrefetch([uid])
            try await Self.waitUntil { step.hasEntered }

            cache.configure(accountUID: "acct-B", key: feedCacheTestKey)
            step.release.signal()
            try await Self.waitUntil { await !feed.downloadCountersForTesting().workersRunning }
            #expect(await !feed.downloadCountersForTesting().workersRunning, "the refresh of the old session ends")
            await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
        }

        @Test func aWindowWithoutAPermitRunsNoCoverageStep() async throws {
            let clock = MutableClock(Date(timeIntervalSince1970: 10_000))
            let runtimeState = LibraryRuntimeState(
                initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted))
            let coordinator = await Self.coordinator(runtimeState)
            let cache = Self.cache("coverage-no-permit", runtimeState: runtimeState)
            let visible = Self.uid("coverage-no-permit-visible")
            cache.storeToDisk(Self.pngData(width: 8, height: 8), for: visible)
            let feed = ThumbnailFeedCore(
                cache: cache, loader: RecordingLoader(failAll: true),
                configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1),
                clock: { clock.read() }, resourceCoordinator: coordinator
            )
            let backupEntered = OneShotGate()
            let backupRelease = OneShotGate()
            let steps = Counter()
            // The first coverage step lets a backup item queue and makes the refresh give up, so coverage stays open.
            feed.setCoverageScanStepHookForTesting {
                steps.increment()
                guard steps.value() == 1 else { return }
                Task {
                    _ = try? await coordinator.withHeavyPermit(
                        LibraryWorkRequest(workload: .backupHashing, intent: .automatic)
                    ) { _ in
                        await backupEntered.open()
                        await backupRelease.wait()
                    }
                }
                feed.noteVisibleDemand()
            }
            defer { feed.setCoverageScanStepHookForTesting(nil) }
            await feed.startPrefetch([Self.uid("coverage-no-permit-crawl")])
            #expect(await backupEntered.wait(), "the backup item takes the permit after the refresh gave up")
            try await Self.waitUntil { await coordinator.waitingPermitCount == 1 }

            // A photo on screen ends the worker's wait; its disk probe, a cache hit, ends after the demand window.
            let probe = BlockingDiskProbeHook()
            feed.setDiskProbeHookForTesting { probe.wait() }
            defer {
                probe.release.signal()
                feed.setDiskProbeHookForTesting(nil)
            }
            _ = await feed.requestPriority(visible)
            try await Self.waitUntil { probe.hasEntered }
            clock.advance(10)
            probe.release.signal()

            try await Self.waitUntil { await coordinator.waitingPermitCount == 1 }
            #expect(await coordinator.waitingPermitCount == 1, "the worker waits for the permit again")
            #expect(steps.value() == 1, "no coverage step while the backup item holds the permit")
            await backupRelease.open()
            try await Self.waitUntil { steps.value() > 1 }
            #expect(steps.value() > 1, "under the permit the coverage check goes on")
            await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
        }

        @Test func aCrawlInAWindowWaitsForASlotWithoutThePermitOrItsPhotos() async throws {
            let a = Self.uid("slot-first-a")
            let b = Self.uid("slot-first-b")
            let runtimeState = LibraryRuntimeState(
                initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted))
            let coordinator = await Self.coordinator(runtimeState)
            let steps = Counter()
            let stepsBeforeSecondPhoto = ValueBox<Int>()
            // The first load ignores cancellation and keeps the only slot after its timeout until the gate opens.
            let loader = GatedLoader(payload: Self.pngData(width: 24, height: 24), gatedCalls: [0]) { _, uids in
                if uids.contains(b) { stepsBeforeSecondPhoto.set(steps.value()) }
            }
            let feed = ThumbnailFeedCore(
                cache: Self.cache("slot-first", runtimeState: runtimeState), loader: loader,
                configuration: Self.configuration(
                    downloadConcurrencyLimit: 1, batchSize: 1, downloadTimeoutSeconds: 0.2),
                resourceCoordinator: coordinator
            )
            feed.setCoverageScanStepHookForTesting { steps.increment() }
            defer { feed.setCoverageScanStepHookForTesting(nil) }
            let slotWaits = Counter()
            await feed.setDownloadSlotWaitHookForTesting { slotWaits.increment() }
            await feed.startPrefetch([a, b])
            try await Self.waitUntil { slotWaits.value() >= 3 }
            #expect(await coordinator.metrics().permitsAcquired == 1, "the wait for a slot holds no permit")

            // A backup item gets the permit while the slot is still taken.
            let backupEntered = OneShotGate()
            let backup = Task {
                _ = try? await coordinator.withHeavyPermit(
                    LibraryWorkRequest(workload: .backupHashing, intent: .automatic)
                ) { _ in await backupEntered.open() }
            }
            #expect(await backupEntered.wait(), "backup does not wait behind the slot")
            await Self.join(backup, "the backup item ends")

            // The app is suspended before the slot frees; the waiting batch has taken no photo, so none is lost.
            runtimeState.update { $0.executionOpportunity = .suspended }
            await loader.open(0)
            try await Self.waitUntil { await feed.crawlWakePendingForTesting() }
            runtimeState.update { $0.executionOpportunity = .foregroundActive }
            try await Self.waitUntil { stepsBeforeSecondPhoto.value != nil }
            // A dropped photo would load only after the end-of-crawl coverage check had scanned for it.
            #expect(stepsBeforeSecondPhoto.value == 0, "the second photo loads in its round, not later")
            await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
        }

        @Test func twoWorkersInAWindowNeverExceedTheDownloadSlots() async throws {
            let runtimeState = LibraryRuntimeState(
                initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted))
            let coordinator = await Self.coordinator(runtimeState)
            let loader = GatedLoader(payload: Self.pngData(width: 24, height: 24), gatedCalls: [0, 1])
            // Two workers, one slot.
            let feed = ThumbnailFeedCore(
                cache: Self.cache("slot-limit", runtimeState: runtimeState), loader: loader,
                configuration: Self.configuration(
                    downloadConcurrencyLimit: 2, initialDownloadConcurrency: 1, batchSize: 1,
                    downloadTimeoutSeconds: 0.2),
                resourceCoordinator: coordinator
            )
            let slotWaits = Counter()
            await feed.setDownloadSlotWaitHookForTesting { slotWaits.increment() }
            await feed.startPrefetch((0..<3).map { Self.uid("slot-limit-\($0)") })
            try await Self.waitUntil { slotWaits.value() >= 3 }

            // The first loader returns; the next batch times out and keeps the slot; the other worker must wait.
            await loader.open(0)
            try await Self.waitUntil { await loader.calls.count == 2 }
            try await Self.waitUntil { await feed.downloadCountersForTesting().activeDownloaders == 0 }
            let waits = slotWaits.value()
            try await Self.waitUntil { slotWaits.value() >= waits + 3 }
            #expect(await loader.calls.count == 2, "no third load while a timed-out one keeps the only slot")
            #expect(await loader.peakOutstanding <= 1, "never two outstanding loads above the limit")

            await loader.open(1)
            try await Self.waitUntil { await loader.calls.count == 3 }
            #expect(await loader.peakOutstanding <= 1)
            await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
        }

        @Test func aSlotTakenDuringThePermitWaitHoldsTheCrawlBatch() async throws {
            let clock = MutableClock(Date(timeIntervalSince1970: 50_000))
            let visible = Self.uid("slot-at-permit-visible")
            let runtimeState = LibraryRuntimeState(
                initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted))
            // The photo on screen is the first load and stays open until the gate opens.
            let loader = GatedLoader(payload: Self.pngData(width: 24, height: 24), gatedCalls: [0])
            let feed = ThumbnailFeedCore(
                cache: Self.cache("slot-at-permit", runtimeState: runtimeState), loader: loader,
                configuration: Self.configuration(
                    downloadConcurrencyLimit: 2, initialDownloadConcurrency: 1, batchSize: 1,
                    downloadTimeoutSeconds: 5),
                clock: { clock.read() }, resourceCoordinator: await Self.coordinator(runtimeState)
            )
            let slotWaits = Counter()
            await feed.setDownloadSlotWaitHookForTesting { slotWaits.increment() }
            let returned = OneShotGate()
            let resume = OneShotGate()
            let first = FirstCall()
            // The crawl worker that gets the permit is held there while a photo on screen takes the only slot.
            await feed.setWindowPermitReturnHookForTesting {
                guard first.take() else { return }
                await returned.open()
                await resume.wait()
            }
            await feed.startPrefetch([Self.uid("slot-at-permit-crawl")])
            #expect(await returned.wait(), "a crawl worker gets the permit")
            _ = await feed.requestPriority(visible)
            try await Self.waitUntil { await loader.calls == [visible] }
            // The demand window of the photo on screen ends, so only the slot holds the crawl batch back.
            clock.advance(10)
            let waits = slotWaits.value()
            await resume.open()
            try await Self.waitUntil {
                let loads = await loader.calls.count
                return slotWaits.value() >= waits + 3 || loads > 1
            }
            #expect(await loader.calls == [visible], "the crawl batch waits for the slot")
            #expect(await loader.peakOutstanding <= 1, "never two loads in one slot")

            await loader.open(0)
            try await Self.waitUntil { await loader.calls.count == 2 }
            #expect(await loader.peakOutstanding <= 1)
            await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
        }

        @Test func aStopWhileTheCrawlWaitsForThePermitStartsNoLoad() async throws {
            let runtimeState = LibraryRuntimeState(
                initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted))
            let coordinator = await Self.coordinator(runtimeState)
            let loader = GatedLoader(payload: Self.pngData(width: 24, height: 24), gatedCalls: [0])
            let feed = ThumbnailFeedCore(
                cache: Self.cache("stop-at-permit", runtimeState: runtimeState), loader: loader,
                configuration: Self.configuration(
                    downloadConcurrencyLimit: 1, batchSize: 1, downloadTimeoutSeconds: 0.2),
                resourceCoordinator: coordinator
            )
            let slotWaits = Counter()
            await feed.setDownloadSlotWaitHookForTesting { slotWaits.increment() }
            let returned = OneShotGate()
            let resume = OneShotGate()
            let first = FirstCall()
            // The wait that the return to the foreground ends is held until the crawl was stopped.
            await feed.setWindowPermitReturnHookForTesting {
                guard runtimeState.snapshot().executionOpportunity != .backgroundPermitted, first.take() else { return }
                await returned.open()
                await resume.wait()
            }
            await feed.startPrefetch([Self.uid("stop-at-permit-a"), Self.uid("stop-at-permit-b")])
            try await Self.waitUntil { slotWaits.value() >= 3 }
            let backupEntered = OneShotGate()
            let backupRelease = OneShotGate()
            let backup = Task {
                _ = try? await coordinator.withHeavyPermit(
                    LibraryWorkRequest(workload: .backupHashing, intent: .automatic)
                ) { _ in
                    await backupEntered.open()
                    await backupRelease.wait()
                }
            }
            #expect(await backupEntered.wait())
            // The slot frees; the crawl now waits for the permit that the backup item holds.
            await loader.open(0)
            try await Self.waitUntil { await coordinator.waitingPermitCount == 1 }

            // The return to the foreground ends the wait, and the crawl is stopped before the worker goes on.
            runtimeState.update { $0.executionOpportunity = .foregroundActive }
            #expect(await returned.wait(), "the wait for the permit ends")
            await feed.stopPrefetch()
            await resume.open()
            await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
            #expect(await loader.calls.count == 1, "the stopped worker starts no load")
            #expect(
                await feed.coverageRefreshStartCountForTesting() == 0, "the stopped worker starts no coverage check")
            await backupRelease.open()
            await Self.join(backup, "the backup item ends")
        }

        @Test func aPhotoProbeThatEndsInAWindowRunsNoCoverageStepWithoutThePermit() async throws {
            let clock = MutableClock(Date(timeIntervalSince1970: 20_000))
            let runtimeState = LibraryRuntimeState(
                initial: LibraryRuntimeSnapshot(executionOpportunity: .foregroundActive))
            let coordinator = await Self.coordinator(runtimeState)
            let cache = Self.cache("probe-into-window", runtimeState: runtimeState)
            let visible = Self.uid("probe-into-window-visible")
            cache.storeToDisk(Self.pngData(width: 8, height: 8), for: visible)
            let crawlLoader = RecordingLoader(failAll: true)
            let feed = ThumbnailFeedCore(
                cache: cache, loader: crawlLoader,
                configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1),
                clock: { clock.read() }, resourceCoordinator: coordinator
            )
            let steps = Counter()
            let first = FirstCall()
            // A photo on screen during the first coverage step keeps the check waiting in the foreground.
            feed.setCoverageScanStepHookForTesting {
                steps.increment()
                if first.take() { feed.noteVisibleDemand() }
            }
            defer { feed.setCoverageScanStepHookForTesting(nil) }
            await feed.startPrefetch([Self.uid("probe-into-window-crawl")])
            try await Self.waitUntil { steps.value() == 1 }

            let probe = BlockingDiskProbeHook()
            feed.setDiskProbeHookForTesting { probe.wait() }
            defer {
                probe.release.signal()
                feed.setDiskProbeHookForTesting(nil)
            }
            _ = await feed.requestPriority(visible)
            try await Self.waitUntil { probe.hasEntered }
            // The window begins and backup takes the permit before the probe ends after the demand window.
            runtimeState.update { $0.executionOpportunity = .backgroundPermitted }
            let backupEntered = OneShotGate()
            let backupRelease = OneShotGate()
            let backup = Task {
                _ = try? await coordinator.withHeavyPermit(
                    LibraryWorkRequest(workload: .backupHashing, intent: .automatic)
                ) { _ in
                    await backupEntered.open()
                    await backupRelease.wait()
                }
            }
            #expect(await backupEntered.wait())
            let startsBeforeTheWindow = await feed.coverageRefreshStartCountForTesting()
            clock.advance(10)
            probe.release.signal()

            try await Self.waitUntil { await coordinator.waitingPermitCount == 1 }
            #expect(steps.value() == 1, "no coverage step in the window without the permit")
            #expect(
                await feed.coverageRefreshStartCountForTesting() == startsBeforeTheWindow,
                "no coverage check starts in the window without the permit")
            await backupRelease.open()
            try await Self.waitUntil { steps.value() > 1 }
            #expect(steps.value() > 1, "with the permit the coverage check goes on")
            await Self.join(backup, "the backup item ends")
            await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
        }

        @Test func aSuspendedAppWithAFinishedCrawlRunsNoCoverageStepAndDoesNotSpin() async throws {
            let clock = MutableClock(Date(timeIntervalSince1970: 30_000))
            let runtimeState = LibraryRuntimeState(
                initial: LibraryRuntimeSnapshot(executionOpportunity: .foregroundActive))
            let crawlLoader = RecordingLoader(failAll: true)
            let feed = ThumbnailFeedCore(
                cache: Self.cache("suspended-coverage", runtimeState: runtimeState),
                loader: crawlLoader,
                configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1),
                clock: { clock.read() }
            )
            let steps = Counter()
            let first = FirstCall()
            // A photo on screen during the first coverage step keeps the check waiting in the foreground.
            feed.setCoverageScanStepHookForTesting {
                steps.increment()
                if first.take() { feed.noteVisibleDemand() }
            }
            defer { feed.setCoverageScanStepHookForTesting(nil) }
            await feed.startPrefetch([Self.uid("suspended-coverage-crawl")])
            try await Self.waitUntil { steps.value() == 1 }
            #expect(await crawlLoader.finishedBatches() == 1)
            #expect(await feed.workerStartCountForTesting() == 1)

            runtimeState.update { $0.executionOpportunity = .suspended }
            clock.advance(10)
            try await Self.waitUntil { await feed.crawlWakePendingForTesting() }
            #expect(await feed.crawlWakePendingForTesting(), "the worker sleeps until the app returns")
            #expect(steps.value() == 1, "no coverage step while suspended")
            #expect(await feed.workerStartCountForTesting() == 1, "no worker started again")
            await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
        }

        @Test func aCoverageCheckStopsWhenTheAppIsSuspended() async throws {
            let runtimeState = LibraryRuntimeState(
                initial: LibraryRuntimeSnapshot(executionOpportunity: .foregroundActive))
            let uids = (0..<2_000).map { Self.uid("suspend-coverage-step-\($0)") }
            // Every second photo arrives: each batch completes without a backoff, and half the coverage stays open.
            let payload = Self.pngData(width: 8, height: 8)
            let delivered = Dictionary(
                uniqueKeysWithValues: uids.enumerated().filter { $0.offset % 2 == 0 }.map {
                    ($0.element, payload)
                })
            let feed = ThumbnailFeedCore(
                cache: Self.cache("suspend-coverage-step", runtimeState: runtimeState),
                loader: RecordingLoader(payloads: delivered),
                configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 16)
            )
            let steps = Counter()
            let first = FirstCall()
            // The app is suspended during the first of four coverage steps.
            feed.setCoverageScanStepHookForTesting {
                steps.increment()
                if first.take() { runtimeState.update { $0.executionOpportunity = .suspended } }
            }
            defer { feed.setCoverageScanStepHookForTesting(nil) }
            await feed.startPrefetch(uids)
            try await Self.waitUntil { await feed.crawlWakePendingForTesting() }
            #expect(await feed.crawlWakePendingForTesting(), "the worker sleeps until the app returns")
            #expect(steps.value() == 1, "the coverage check stops after the step in which the app was suspended")
            await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
        }

        @Test func aPhotoOnScreenDuringTheSlotWaitLoadsWithoutAPermitInLowPowerMode() async throws {
            let visible = Self.uid("slot-wait-visible")
            let runtimeState = LibraryRuntimeState(
                initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted))
            let coordinator = await Self.coordinator(runtimeState)
            // The first crawl load ignores cancellation and keeps the only slot after its timeout until the gate opens.
            let loader = GatedLoader(payload: Self.pngData(width: 24, height: 24), gatedCalls: [0])
            let feed = ThumbnailFeedCore(
                cache: Self.cache("slot-wait-visible", runtimeState: runtimeState), loader: loader,
                configuration: Self.configuration(
                    downloadConcurrencyLimit: 2, initialDownloadConcurrency: 1, batchSize: 1,
                    downloadTimeoutSeconds: 0.2),
                resourceCoordinator: coordinator
            )
            let slotWaits = Counter()
            await feed.setDownloadSlotWaitHookForTesting { slotWaits.increment() }
            await feed.startPrefetch([Self.uid("slot-wait-visible-a"), Self.uid("slot-wait-visible-b")])
            try await Self.waitUntil { await loader.calls.count == 1 }
            try await Self.waitUntil { await feed.downloadCountersForTesting().activeDownloaders == 0 }
            let waits = slotWaits.value()
            try await Self.waitUntil { slotWaits.value() >= waits + 4 }
            let permits = await coordinator.metrics().permitsAcquired

            // While both workers wait for the slot, Low Power Mode begins and a photo appears on screen.
            runtimeState.update { $0.isLowPowerMode = true }
            _ = await feed.requestPriority(visible)
            await loader.open(0)
            try await Self.waitUntil { await loader.calls.contains(visible) }
            #expect(await loader.calls.contains(visible), "the photo on screen loads once the slot is free")
            #expect(await coordinator.metrics().permitsAcquired == permits, "without a crawl permit")
            await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
        }

        @Test func aHeldCoverageCheckGoesOnWhenTheAppReturnsBeforeTheWorkersStop() async throws {
            let (feed, runtimeState, steps, uids) = Self.suspendingCoverageFeed("coverage-wake-first")
            defer { feed.setCoverageScanStepHookForTesting(nil) }
            let stopGate = BlockingDiskProbeHook()
            let firstStop = FirstCall()
            feed.setWorkersStoppedHookForTesting { if firstStop.take() { stopGate.wait() } }
            defer {
                stopGate.release.signal()
                feed.setWorkersStoppedHookForTesting(nil)
            }
            await feed.startPrefetch(uids)
            // The suspension stops the coverage check; the worker installs its wake and returns.
            try await Self.waitUntil { stopGate.hasEntered }
            try #require(stopGate.hasEntered)
            #expect(await feed.crawlWakePendingForTesting())
            #expect(steps.value() == 1)

            runtimeState.update { $0.executionOpportunity = .foregroundActive }
            try await Self.waitUntil { await !feed.crawlWakePendingForTesting() }
            try #require(await !feed.crawlWakePendingForTesting(), "the wake ran while the workers were still marked")
            stopGate.release.signal()

            try await Self.waitUntil { steps.value() > 1 }
            #expect(steps.value() > 1, "the coverage check goes on")
            await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
        }

        @Test func aHeldCoverageCheckGoesOnWhenTheAppReturnsAfterTheWorkersStop() async throws {
            let (feed, runtimeState, steps, uids) = Self.suspendingCoverageFeed("coverage-stop-first")
            defer { feed.setCoverageScanStepHookForTesting(nil) }
            await feed.startPrefetch(uids)
            try await Self.waitUntil {
                let running = await feed.downloadCountersForTesting().workersRunning
                return await feed.crawlWakePendingForTesting() && !running
            }
            let starts = await feed.workerStartCountForTesting()
            // A restart loop starts workers again within milliseconds; a slow machine can only hide one.
            try await Task.sleep(for: .milliseconds(300))
            #expect(await feed.workerStartCountForTesting() == starts, "no worker starts while the app is suspended")
            #expect(steps.value() == 1)

            runtimeState.update { $0.executionOpportunity = .foregroundActive }
            try await Self.waitUntil { steps.value() > 1 }
            #expect(steps.value() > 1, "the coverage check goes on")
            #expect(await feed.workerStartCountForTesting() == starts + 1)
            await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
        }

        @Test func aWindowBatchThatTurnsOutEmptyGivesItsSlotBack() async throws {
            let saved = Self.uid("empty-batch-saved")
            let next = Self.uid("empty-batch-next")
            let runtimeState = LibraryRuntimeState(
                initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted))
            let cache = Self.cache("empty-batch", runtimeState: runtimeState)
            cache.storeToDisk(Self.pngData(width: 8, height: 8), for: saved)
            let loader = PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24))
            // One slot: the first batch is a disk hit and must give the slot back for the second one.
            let feed = ThumbnailFeedCore(
                cache: cache, loader: loader,
                configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1),
                resourceCoordinator: await Self.coordinator(runtimeState)
            )
            await feed.startPrefetch([saved, next])
            try await Self.waitUntil { await loader.recordedPriorities.count == 1 }
            #expect(await loader.recordedPriorities.count == 1, "the next photo loads after the empty batch")
            await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
            // Every worker has ended, so every batch has given its slot back.
            #expect(await feed.downloadCountersForTesting().activeDownloaders == 0, "no slot stays counted")
        }

        @Test func aSessionChangeWithAQueuedPhotoStartsNoWorkersAgain() async throws {
            let cache = Self.cache("stale-restart")
            let feed = ThumbnailFeedCore(
                cache: cache, loader: RecordingLoader(failAll: true),
                configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
            )
            let requested = FlagBox()
            let first = FirstCall()
            // During the coverage check a photo on screen is queued and the account changes.
            feed.setCoverageScanStepHookForTesting {
                guard first.take() else { return }
                Task {
                    _ = await feed.requestPriority(Self.uid("stale-restart-visible"))
                    requested.set()
                }
                cache.configure(accountUID: "acct-B", key: feedCacheTestKey)
            }
            defer { feed.setCoverageScanStepHookForTesting(nil) }
            await feed.startPrefetch([Self.uid("stale-restart-crawl")])
            try await Self.waitUntil { requested.isSet }
            try await Self.waitUntil { await !feed.downloadCountersForTesting().workersRunning }
            let starts = await feed.workerStartCountForTesting()
            // A restart loop starts workers again within milliseconds; a slow machine can only hide one.
            try await Task.sleep(for: .milliseconds(300))
            #expect(await feed.workerStartCountForTesting() == starts, "no new workers for the session that ended")
            await Self.join(Task { await feed.stopPrefetchAndWait() }, "the feed stops")
        }

        @Test func theCoverageRefreshStopsWhenItsTaskIsCancelled() async throws {
            let (feed, uids) = Self.refreshFeed("refresh-cancel")
            let steps = Counter()
            let gate = BlockingDiskProbeHook()
            feed.setCoverageScanStepHookForTesting {
                steps.increment()
                if steps.value() == 2 { gate.wait() }
            }
            defer {
                gate.release.signal()
                feed.setCoverageScanStepHookForTesting(nil)
            }
            let refresh = Task { await feed.runCoverageRefreshForTesting(seeding: uids, shouldStop: { false }) }
            try await Self.waitUntil { gate.hasEntered }
            refresh.cancel()
            gate.release.signal()
            let outcome = await Self.value(of: refresh)
            #expect(outcome == "aborted")
            #expect(steps.value() == 2, "no further scan step after the cancellation")
        }

        @Test func theCoverageRefreshStopsWhenThePermitMustBeGivenBack() async throws {
            let (feed, uids) = Self.refreshFeed("refresh-stop")
            let steps = Counter()
            let stop = FlagBox()
            feed.setCoverageScanStepHookForTesting {
                steps.increment()
                if steps.value() == 2 { stop.set() }
            }
            defer { feed.setCoverageScanStepHookForTesting(nil) }
            let outcome = await Self.value(
                of: Task { await feed.runCoverageRefreshForTesting(seeding: uids, shouldStop: { stop.isSet }) })
            #expect(outcome == "aborted")
            #expect(steps.value() == 2, "the refresh stops at the next step")
        }
    #endif

    @Test func aCrawlStoppedDuringABatchKeepsItsSavedPhotosAndLoadsOnlyTheRest() async throws {
        let saved = Self.uid("killed-crawl-saved")
        let unsaved = Self.uid("killed-crawl-unsaved")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncryptedMemoriesKit-killed-crawl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = "killed-crawl-\(UUID().uuidString)"
        let runtimeState = LibraryRuntimeState(
            initial: LibraryRuntimeSnapshot(executionOpportunity: .backgroundPermitted))
        func cache() -> ThumbnailCache {
            let cache = ThumbnailCache(namespace: namespace, rootDirectory: root, runtimeState: runtimeState)
            cache.configure(accountUID: "acct-A", key: feedCacheTestKey)
            return cache
        }

        // The first process saves one photo and is ended while the next batch still downloads.
        let first = FirstBatchThenHangingLoader(payload: Self.pngData(width: 24, height: 24))
        let firstFeed = ThumbnailFeedCore(
            cache: cache(), loader: first,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1),
            resourceCoordinator: await Self.coordinator(runtimeState)
        )
        await firstFeed.startPrefetch([saved, unsaved])
        try await Self.waitUntil { await first.requests == [saved, unsaved] }
        #expect(await first.requests == [saved, unsaved], "the second batch was downloading")
        await firstFeed.stopPrefetchAndWait()

        // The next process opens the same cache: the saved photo is whole, only the other photo loads.
        let next = RecordingLoader(payloads: [unsaved: Self.pngData(width: 24, height: 24)])
        let nextFeed = ThumbnailFeedCore(
            cache: cache(), loader: next,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1),
            resourceCoordinator: await Self.coordinator(runtimeState)
        )
        await nextFeed.startPrefetch([saved, unsaved])
        try await Self.waitUntil { await next.requestCount() == 1 }
        try await Self.waitUntil { await nextFeed.prefetchStatus().currentQueueLength == 0 }
        #expect(await next.requestOrder() == [unsaved], "the saved photo is not downloaded again")
        #expect(await nextFeed.prefetchStatus().diskHit >= 1, "the saved photo is read from the cache")
        await nextFeed.stopPrefetchAndWait()
    }

    #if DEBUG
        /// A withheld photo is the only crawl work left when the hold begins. The hold ends after the last worker
        /// returned but before the feed records the stop, so the wake finds the workers still marked running.
        @Test(arguments: CrawlHold.allCases)
        func aWithheldRetryLoadsWhenTheHoldEndsJustBeforeTheWorkersStop(_ hold: CrawlHold) async throws {
            let uid = Self.uid("withheld-hold-\(hold.rawValue)")
            let runtimeState = LibraryRuntimeState(initial: LibraryRuntimeSnapshot())
            let loader = WithheldOnceLoader(payload: Self.pngData(width: 24, height: 24)) {
                hold.begin(in: runtimeState)
            }
            let feed = ThumbnailFeedCore(
                cache: Self.cache("withheld-hold-\(hold.rawValue)", runtimeState: runtimeState),
                loader: loader,
                configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
            )
            let stopGate = BlockingDiskProbeHook()
            let firstStop = FirstCall()
            feed.setWorkersStoppedHookForTesting { if firstStop.take() { stopGate.wait() } }
            defer {
                stopGate.release.signal()
                feed.setWorkersStoppedHookForTesting(nil)
            }

            await feed.startPrefetch([uid])
            // The first load withholds the photo and begins the hold; the worker installs its wake and returns.
            try await Self.waitUntil { stopGate.hasEntered }
            try #require(stopGate.hasEntered)
            #expect(await feed.crawlWakePendingForTesting())

            hold.end(in: runtimeState)
            try await Self.waitUntil { await !feed.crawlWakePendingForTesting() }
            try #require(await !feed.crawlWakePendingForTesting(), "the wake ran while the workers were still marked")
            stopGate.release.signal()

            try await Self.waitUntil { await loader.requests(for: uid) == 2 }
            #expect(await loader.requests(for: uid) == 2, "the withheld photo loads again")
            await feed.stopPrefetchAndWait()
        }
    #endif

    @Test(arguments: [LibraryExecutionOpportunity.foregroundActive, .foregroundInactive])
    func aForegroundCrawlTakesNoPermit(_ opportunity: LibraryExecutionOpportunity) async throws {
        let crawled = [Self.uid("foreground-crawl-a"), Self.uid("foreground-crawl-b")]
        let loader = PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24))
        let runtimeState = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(executionOpportunity: opportunity))
        let coordinator = await Self.coordinator(runtimeState)
        let feed = ThumbnailFeedCore(
            cache: Self.cache("foreground-crawl", runtimeState: runtimeState),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 2, batchSize: 1),
            resourceCoordinator: coordinator
        )
        await feed.startPrefetch(crawled)

        try await Self.waitUntil { await loader.recordedPriorities.count == 2 }
        #expect(await loader.recordedPriorities == [.idleLibraryCrawl, .idleLibraryCrawl])
        #expect(await coordinator.metrics().permitsAcquired == 0, "the foreground crawl runs as before")
        await feed.stopPrefetchAndWait()
    }

    @Test func crawlRunsWhileTheAppIsInTheForegroundButInactive() async throws {
        // A Mac app behind another window, or an iPhone app under Control Center, is not in a background window.
        let crawled = [Self.uid("inactive-crawl-a"), Self.uid("inactive-crawl-b")]
        let loader = PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24))
        let runtimeState = LibraryRuntimeState(
            initial: LibraryRuntimeSnapshot(executionOpportunity: .foregroundInactive))
        let feed = ThumbnailFeedCore(
            cache: Self.cache("inactive-crawl", runtimeState: runtimeState),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 2, batchSize: 1)
        )
        await feed.startPrefetch(crawled)

        try await Self.waitUntil { await loader.recordedPriorities.count == 2 }
        #expect(await loader.recordedPriorities == [.idleLibraryCrawl, .idleLibraryCrawl])
        await feed.stopPrefetchAndWait()
    }

    @Test func localPendingPhotosLoadFromTheDeviceOnly() async throws {
        let local = PhotoUID(localPending: .photoLibrary, identifier: "asset-1")
        let remoteLoader = PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24))
        let localLoader = StubLocalThumbnails(image: Self.decodedThumb(16, 16))
        let feed = ThumbnailFeedCore(
            cache: Self.cache("local-pending"),
            loader: remoteLoader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 4)
        )
        await feed.setLocalThumbnailLoader(localLoader)

        _ = await feed.warmVisibleDecoded([ThumbnailRequest(uid: local)], limit: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await feed.cachedDecoded(for: local) == nil, "an unauthorized local photo never loads")

        await feed.setLocalAuthorization([local])
        _ = await feed.warmVisibleDecoded([ThumbnailRequest(uid: local)], limit: 1)
        try await Self.waitUntil { await feed.cachedDecoded(for: local) != nil }
        #expect(await remoteLoader.recordedPriorities.isEmpty, "Proton never sees a local identity")

        await feed.setLocalAuthorization([])
        #expect(await feed.cachedDecoded(for: local) == nil, "leaving the pending set drops the image")
    }

    @Test func largerLocalRequestLoadsOnceAtTheNewSize() async throws {
        let local = PhotoUID(localPending: .photoLibrary, identifier: "asset-3")
        let sizes = LocalRequestSizes()
        let feed = ThumbnailFeedCore(
            cache: Self.cache("local-upgrade"),
            loader: PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24)),
            configuration: Self.configuration()
        )
        await feed.setLocalThumbnailLoader(StubLocalThumbnails(image: Self.decodedThumb(16, 16), sizes: sizes))
        await feed.setLocalAuthorization([local])
        _ = await feed.decoded(for: local)
        #expect(feed.decodedNeedsSharperSource(local, forPixels: 64))

        _ = await feed.warmVisibleDecoded([ThumbnailRequest(uid: local, pixelSize: 64)], limit: 1)
        try await Self.waitUntil { !feed.decodedNeedsSharperSource(local, forPixels: 64) }
        #expect(await sizes.values == [16, 64], "a smaller device source must not keep the tile asking again")
        _ = await feed.warmVisibleDecoded([ThumbnailRequest(uid: local, pixelSize: 64)], limit: 1)
        #expect(await sizes.values == [16, 64])
    }

    @Test func slowLocalLoadNeitherBlocksOthersNorOutlivesItsGrid() async throws {
        let slow = PhotoUID(localPending: .photoLibrary, identifier: "slow")
        let fast = PhotoUID(localPending: .photoLibrary, identifier: "fast")
        let cancellations = LocalCancellations()
        let feed = ThumbnailFeedCore(
            cache: Self.cache("local-slow"),
            loader: PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24)),
            configuration: Self.configuration()
        )
        await feed.setLocalThumbnailLoader(
            SlowLocalThumbnails(image: Self.decodedThumb(16, 16), slow: slow, cancellations: cancellations))
        await feed.setLocalAuthorization([slow, fast])

        feed.submitVisibleDiskDecodeDemand([ThumbnailRequest(uid: slow), ThumbnailRequest(uid: fast)])
        try await Self.waitUntil { feed.memoryDecoded(for: fast) != nil }

        // Another viewport replaces the queue but lets the running download finish.
        feed.submitVisibleDiskDecodeDemand([ThumbnailRequest(uid: fast)])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await cancellations.count == 0)

        // The grid leaves the screen: its download stops, and a cancelled load is no failure.
        await feed.endLocalVisibleDemand()
        try await Self.waitUntil { await cancellations.count == 1 }
        #expect(!feed.isKnownUnfetchable(slow))

        // Returning while the cancelled load still finishes starts it again.
        feed.submitVisibleDiskDecodeDemand([ThumbnailRequest(uid: slow)])
        try await Self.waitUntil { await cancellations.starts == 2 }
        await feed.endLocalVisibleDemand()
        feed.submitVisibleDiskDecodeDemand([ThumbnailRequest(uid: slow)])
        try await Self.waitUntil { await cancellations.starts == 3 }
    }

    @Test func localDemandBeforeAuthorizationLoadsOnceAuthorized() async throws {
        let local = PhotoUID(localPending: .photoLibrary, identifier: "asset-5")
        let feed = ThumbnailFeedCore(
            cache: Self.cache("local-replay"),
            loader: PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24)),
            configuration: Self.configuration()
        )
        await feed.setLocalThumbnailLoader(StubLocalThumbnails(image: Self.decodedThumb(16, 16)))
        feed.submitVisibleDiskDecodeDemand([ThumbnailRequest(uid: local, pixelSize: 16)])
        try await Task.sleep(for: .milliseconds(50))
        #expect(feed.memoryDecoded(for: local) == nil)

        await feed.setLocalAuthorization([local])
        try await Self.waitUntil { feed.memoryDecoded(for: local) != nil }
    }

    @Test func handoverAdoptsBeforeTheLocalImageIsDropped() async throws {
        let local = PhotoUID(localPending: .photoLibrary, identifier: "asset-4")
        let remote = Self.uid("handover")
        let feed = ThumbnailFeedCore(
            cache: Self.cache("handover"),
            loader: PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24)),
            configuration: Self.configuration()
        )
        await feed.setLocalThumbnailLoader(StubLocalThumbnails(image: Self.decodedThumb(16, 16)))
        await feed.setLocalAuthorization([local])
        _ = await feed.decoded(for: local)

        await feed.setLocalAuthorization([], adoptions: [(local, remote)])
        #expect(await feed.cachedDecoded(for: remote) != nil)
        #expect(await feed.cachedDecoded(for: local) == nil)
    }

    @Test func handoverShowsThePendingImageBeforeTheScopeListsTheProtonPhoto() async throws {
        let local = PhotoUID(localPending: .photoLibrary, identifier: "asset-7")
        let remote = Self.uid("fresh-upload")
        let feed = ThumbnailFeedCore(
            cache: Self.cache("adopt-before-scope"),
            loader: PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24)),
            configuration: Self.configuration()
        )
        // The source scope lists the library but not the photo that just uploaded.
        let graph = LibrarySourceGraph()
        let change = Self.visibleScope(in: graph, uids: [Self.uid("older")])
        #expect(await feed.bindDerivedDataEpoch(graph.runtimeEpoch))
        _ = await feed.reconcile(
            selected: change.selectedScope, analysis: change.analysisScope,
            retention: change.thumbnailRetentionScope)
        await feed.setLocalThumbnailLoader(StubLocalThumbnails(image: Self.decodedThumb(16, 16)))
        await feed.setLocalAuthorization([local])
        _ = await feed.decoded(for: local)

        await feed.setLocalAuthorization([], adoptions: [(local, remote)])
        #expect(feed.memoryDecoded(for: remote) != nil, "the handed-over tile must not turn black")

        // Once the scope lists the photo, the image stays and needs no exception any more.
        let listed = Self.visibleScope(in: graph, uids: [Self.uid("older"), remote])
        _ = await feed.reconcile(
            selected: listed.selectedScope, analysis: listed.analysisScope,
            retention: listed.thumbnailRetentionScope)
        #expect(feed.memoryDecoded(for: remote) != nil)
    }

    @Test func readingAnUnauthorizedPhotoKeepsEveryOtherImage() async throws {
        let shown = PhotoUID(localPending: .photoLibrary, identifier: "asset-9")
        let notYetAuthorized = PhotoUID(localPending: .photoLibrary, identifier: "asset-10")
        let feed = ThumbnailFeedCore(
            cache: Self.cache("unauthorized-read"),
            loader: PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24)),
            configuration: Self.configuration()
        )
        await feed.setLocalThumbnailLoader(StubLocalThumbnails(image: Self.decodedThumb(16, 16)))
        await feed.setLocalAuthorization([shown])
        _ = await feed.decoded(for: shown)

        // The grid lists a new photo a moment before its authorization arrives, and a new Proton photo before the
        // source scope covers it. Such a read misses; it must not empty the RAM tier the viewer opens from.
        #expect(feed.memoryDecoded(for: notYetAuthorized) == nil)
        #expect(feed.memoryDecoded(for: Self.uid("unlisted")) == nil)
        #expect(await feed.decoded(for: notYetAuthorized) == nil)
        #expect(feed.memoryDecoded(for: shown) != nil)
    }

    @Test func revisedLocalPhotoKeepsItsImageUntilTheNewOneLoads() async throws {
        let local = PhotoUID(localPending: .photoLibrary, identifier: "asset-8")
        let feed = ThumbnailFeedCore(
            cache: Self.cache("local-refresh"),
            loader: PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24)),
            configuration: Self.configuration()
        )
        await feed.setLocalThumbnailLoader(StubLocalThumbnails(image: Self.decodedThumb(16, 16)))
        await feed.setLocalAuthorization([local])
        _ = await feed.decoded(for: local)

        // The camera finished processing: a new revision loads while the quick image stays on screen.
        let gate = LocalGate()
        await feed.setLocalThumbnailLoader(GatedLocalThumbnails(image: Self.decodedThumb(32, 32), gate: gate))
        let refresh = Task { await feed.refreshLocal([local]) }
        try await Self.waitUntil { await gate.waiting == 1 }
        #expect(feed.memoryDecoded(for: local)?.image.width == 16, "the tile must not turn black while it reloads")

        await gate.open()
        #expect(await refresh.value == [local])
        #expect(feed.memoryDecoded(for: local)?.image.width == 32)
        #expect(await feed.refreshLocal([Self.uid("remote")]).isEmpty, "only local photos refresh")
    }

    @Test func handoverReadsThePendingImageFromTheDeviceWhenRAMLostIt() async throws {
        let local = PhotoUID(localPending: .photoLibrary, identifier: "asset-11")
        let remote = Self.uid("uploaded-evicted")
        let feed = ThumbnailFeedCore(
            cache: Self.cache("handover-device"),
            loader: PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24)),
            configuration: Self.configuration()
        )
        // Authorized before a device loader exists, so the pending image never reaches RAM (as after an
        // eviction) when its Proton photo takes over.
        await feed.setLocalAuthorization([local])
        #expect(feed.memoryDecoded(for: local) == nil)
        await feed.setLocalThumbnailLoader(StubLocalThumbnails(image: Self.decodedThumb(16, 16)))
        await feed.setLocalAuthorization([], adoptions: [(local, remote)])
        try await Self.waitUntil { feed.memoryDecoded(for: remote) != nil }
        #expect(feed.memoryDecoded(for: local) == nil)
    }

    @Test func protonPhotoAdoptsThePendingImage() async throws {
        let local = PhotoUID(localPending: .photoLibrary, identifier: "asset-2")
        let remote = Self.uid("adopted")
        let feed = ThumbnailFeedCore(
            cache: Self.cache("adopt"),
            loader: PriorityRecordingLoader(payload: Self.pngData(width: 24, height: 24)),
            configuration: Self.configuration()
        )
        await feed.setLocalThumbnailLoader(StubLocalThumbnails(image: Self.decodedThumb(16, 16)))
        await feed.setLocalAuthorization([local])
        _ = await feed.decoded(for: local)

        let adopted = await feed.adoptDecoded(from: local, to: remote)
        #expect(adopted)
        #expect(await feed.cachedDecoded(for: remote) != nil)
    }

    @Test func equalPriorityQueueKeepsNearToFarOrder() async throws {
        let blocker = Self.uid("fifo-blocker")
        let near = Self.uid("fifo-near")
        let middle = Self.uid("fifo-middle")
        let far = Self.uid("fifo-far")
        let loader = ControlledLateLoader(payloads: [:])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("priority-fifo"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.requestPriority(blocker, priority: .visibleNow)
        try await Self.waitUntil { await loader.requestCount() == 1 }
        for uid in [near, middle, far] {
            await feed.requestPriority(uid, priority: .nearViewportScrollAhead)
        }
        await loader.release()
        try await Self.waitUntil { await loader.requestCount() == 4 }

        #expect(await loader.requestedOrder() == [blocker, near, middle, far])
        await feed.stopPrefetch()
    }

    @Test func replacingVisibleDemandRemovesQueuedScrollAhead() async throws {
        let blocker = Self.uid("replace-blocker")
        let staleAhead = (0..<4).map { Self.uid("replace-ahead-\($0)") }
        let currentVisible = [Self.uid("replace-visible-0"), Self.uid("replace-visible-1")]
        let loader = ControlledLateLoader(payloads: [:])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("replace-visible"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.requestPriority(blocker, priority: .visibleNow)
        try await Self.waitUntil { await loader.requestCount() == 1 }
        for uid in staleAhead {
            await feed.requestPriority(uid, priority: .nearViewportScrollAhead)
        }
        #expect(await feed.replaceVisiblePriorityDemand(currentVisible) == currentVisible.count)
        await loader.release()
        try await Self.waitUntil { await loader.requestCount() == 3 }
        try await Task.sleep(for: .milliseconds(100))

        let order = await loader.requestedOrder()
        #expect(order == [blocker] + currentVisible)
        for uid in staleAhead {
            #expect(order.contains(uid) == false)
        }
        await feed.stopPrefetch()
    }

    @Test func coverageCheckpointStoresOnlyOpaqueIdentifiers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumbnail-coverage-opaque-\(UUID().uuidString)", isDirectory: true)
        let uid = PhotoUID(volumeID: "sensitive-volume-id", nodeID: "sensitive-node-id")
        let store = FileThumbnailCoverageCheckpointStore(directory: directory, scope: "account-A")
        store.recordPresent([uid], for: "thumbnail-coverage-v1")

        let file = try #require(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains(uid.volumeID))
        #expect(!text.contains(uid.nodeID))
        #expect(!text.contains(Data(uid.volumeID.utf8).base64EncodedString()))
        #expect(!text.contains(Data(uid.nodeID.utf8).base64EncodedString()))
        #expect(store.loadPresent([uid], for: "thumbnail-coverage-v1") == [uid])
    }

    @Test func coverageCheckpointWritesAreCoalescedAndFlushedAtCompletion() async throws {
        let uids = (0..<260).map { Self.uid("checkpoint-coalesce-\($0)") }
        let cache = Self.cache("checkpoint-coalesce")
        for uid in uids { cache.storeToDisk(Self.pngData(width: 8, height: 8), for: uid) }
        let store = RecordingCoverageStore()
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: RecordingLoader(),
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 4),
            coverageStore: store
        )

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await feed.prefetchStatus().diskCoverageVerified }

        #expect(store.snapshot == Set(uids))
        #expect(store.writeCount <= 3)
        await feed.stopPrefetch()
    }

    @Test func checkpointBootstrapDoesNotBlockVisibleDiskDecode() async throws {
        let uid = Self.uid("bootstrap-visible")
        let cache = Self.cache("bootstrap-visible")
        cache.storeToDisk(Self.pngData(width: 24, height: 24), for: uid)
        let coverage = BlockingCoverageStore()
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: RecordingLoader(),
            configuration: Self.configuration(),
            coverageStore: coverage
        )

        let bootstrap = Task { await feed.startPrefetch([uid]) }
        try await Self.waitUntil { coverage.hasEntered }
        #expect(coverage.hasEntered)

        let warm = await feed.warmDecoded(
            [ThumbnailRequest(uid: uid)],
            priority: .visibleNow,
            limit: 1
        )
        #expect(warm.decodedFromDisk == 1)

        coverage.release.signal()
        await bootstrap.value
        await feed.stopPrefetch()
    }

    @Test func stoppedCheckpointBootstrapCannotRestartOldCrawl() async throws {
        let uid = Self.uid("bootstrap-stale")
        let coverage = BlockingCoverageStore()
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("bootstrap-stale"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1),
            coverageStore: coverage
        )

        let bootstrap = Task { await feed.startPrefetch([uid]) }
        try await Self.waitUntil { coverage.hasEntered }
        #expect(coverage.hasEntered)
        await feed.stopPrefetch()
        coverage.release.signal()
        await bootstrap.value
        try await Task.sleep(for: .milliseconds(100))

        #expect(await loader.requestCount() == 0)
        #expect(await feed.prefetchStatus().currentQueueLength == 0)
    }

    @Test func diskOnlyBytesWarmIntoDecodedRamWithoutNetwork() async throws {
        let uid = Self.uid("disk-only")
        let cache = Self.cache("disk")
        cache.storeToDisk(Self.pngData(width: 24, height: 12), for: uid)
        let loader = RecordingLoader()
        let aspects = LockedAspects()
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(maxConcurrentDecodes: 2),
            onDecoded: { uid, decoded in
                aspects.record(uid, aspect: decoded.aspectRatio)
            }
        )

        let before = await feed.cacheState(for: ThumbnailRequest(uid: uid))
        #expect(before.diskThumbnail)
        #expect(!before.ramDecoded)

        let result = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(result.decodedFromDisk == 1)
        #expect(result.queuedNetwork == 0)
        #expect(result.mainThreadDecodeCount == 0)
        #expect(await loader.requestCount() == 0)
        #expect(feed.memoryDecoded(for: uid) != nil)
        #expect(aspects.value(for: uid).map { abs($0 - 2.0) < 0.2 } == true)

        let after = await feed.cacheState(for: ThumbnailRequest(uid: uid))
        #expect(after.diskThumbnail)
        #expect(after.ramDecoded)
    }

    @Test func prefetchCompletionWaitIncludesLastDownloadAfterQueueDrains() async throws {
        let uid = Self.uid("prefetch-completion")
        let cache = Self.cache("prefetch-completion")
        let loader = ControlledLateLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache, loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1, downloadTimeoutSeconds: 10)
        )
        await feed.startPrefetch([uid])
        try await Self.waitUntil { await loader.isWaiting() }
        #expect(await feed.prefetchStatus().currentQueueLength == 0)
        #expect(await feed.prefetchStatus().downloadsInFlight == 1)

        let completed = Counter()
        let waiter = Task {
            try await feed.waitForPrefetchToFinish()
            completed.increment()
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(completed.value() == 0, "An empty queue must not hide the last in-flight thumbnail")
        await loader.release()
        try await Self.waitUntil { completed.value() == 1 }
        try await waiter.value
        #expect(cache.has(uid))
        await feed.stopPrefetchAndWait()
    }

    @Test func cancellingPrefetchWaitDoesNotCancelTheThumbnailDownload() async throws {
        let uid = Self.uid("cancel-prefetch-wait")
        let loader = ControlledLateLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("cancel-prefetch-wait"), loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1, downloadTimeoutSeconds: 10)
        )
        await feed.startPrefetch([uid])
        try await Self.waitUntil { await loader.isWaiting() }
        let waiter = Task { try await feed.waitForPrefetchToFinish() }
        waiter.cancel()
        do {
            try await waiter.value
            Issue.record("Cancelled presentation waiter must finish without joining the blocked download")
        } catch is CancellationError {}
        #expect(await loader.isWaiting())
        await loader.release()
        try await feed.waitForPrefetchToFinish()
        #expect(await feed.prefetchStatus().downloadCompleted == 1)
        await feed.stopPrefetchAndWait()
    }

    @Test func prefetchCompletionWaitSettlesCachedAndUnavailableThumbnails() async throws {
        let cached = Self.uid("prefetch-cached")
        let unavailable = Self.uid("prefetch-unavailable")
        let cache = Self.cache("prefetch-settled")
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: cached)
        let loader = RecordingLoader(itemErrors: [unavailable: "No thumbnail"])
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration())
        await feed.startPrefetch([cached, unavailable])
        let completed = Counter()
        let waiter = Task {
            try await feed.waitForPrefetchToFinish()
            completed.increment()
        }
        try await Self.waitUntil { completed.value() == 1 }
        try await waiter.value
        #expect(await loader.requestCount() == 1, "Already cached photos must not download again")
        #expect(feed.isKnownUnfetchable(unavailable))
        await feed.stopPrefetchAndWait()
    }

    @Test func libraryUpdateResolutionTreatsDiskThumbnailAsSettledWithoutNetwork() async {
        let uid = Self.uid("library-update-disk")
        let cache = Self.cache("library-update-disk")
        cache.storeToDisk(Self.pngData(width: 24, height: 12), for: uid)
        let loader = RecordingLoader()
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration())

        let resolution = await feed.libraryUpdateResolution(for: [uid], enqueueMissing: true)

        #expect(resolution.availableUIDs == [uid])
        #expect(resolution.terminalUIDs.isEmpty)
        #expect(await loader.requestCount() == 0)
    }

    @Test func libraryUpdateResolutionEnqueuesOnlyMissingNewAssetThumbnail() async throws {
        let uid = Self.uid("library-update-network")
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("library-update-network"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        let initial = await feed.libraryUpdateResolution(for: [uid], enqueueMissing: true)
        #expect(initial.availableUIDs.isEmpty)
        #expect(initial.terminalUIDs.isEmpty)
        try await Self.waitUntil { await loader.fetched(uid) }

        let settled = await feed.libraryUpdateResolution(for: [uid], enqueueMissing: false)
        #expect(settled.availableUIDs == [uid])
        #expect(await loader.requestCount() == 1)
    }

    @Test func cancelledVisibleWarmDoesNotStartAStaleBatch() async {
        let uids = (0..<96).map { Self.uid("cancelled-warm-\($0)") }
        let loader = RecordingLoader()
        let feed = ThumbnailFeedCore(
            cache: Self.cache("cancelled-warm"),
            loader: loader,
            configuration: Self.configuration(maxConcurrentDecodes: 2)
        )

        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await feed.warmDecoded(
                uids.map { ThumbnailRequest(uid: $0) },
                priority: .visibleNow,
                limit: uids.count
            )
        }
        task.cancel()
        let result = await task.value

        #expect(result.requested == uids.count)
        #expect(result.decodedFromDisk == 0)
        #expect(result.queuedNetwork == 0)
        #expect(await loader.requestCount() == 0)
    }

    @Test func networkDeliveryWakesHostWhenViewportLive() async throws {
        // The crawl worker stores network arrivals to disk only. Without an arrival wake, a grid host whose
        // A visible set that does not change never re-warms those bytes into RAM, leaving the tile black until
        // the user scrolls. This proves the shared wake fires when a delivery lands while a viewport is live.
        let uid = Self.uid("wake-live")
        let cache = Self.cache("wake-live")  // The empty disk cache forces a fetch over the fake network.
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache, loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )
        let wakes = Counter()
        let registration = await feed.setOnImagesAvailable { wakes.increment() }

        feed.noteVisibleDemand()  // A live viewport must wake when data arrives.
        await feed.requestPriority(uid, priority: .visibleNow)  // enqueue the disk-miss for the crawl worker

        try await Self.waitUntil { wakes.value() > 0 }
        #expect(wakes.value() > 0)
        #expect(await loader.fetched(uid))
        registration.end()
    }

    @Test func networkDeliveryWakesEveryRegisteredHost() async throws {
        let uid = Self.uid("wake-multicast")
        let cache = Self.cache("wake-multicast")
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache, loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )
        let firstWakes = Counter()
        let secondWakes = Counter()
        let firstRegistration = await feed.setOnImagesAvailable { firstWakes.increment() }
        let secondRegistration = await feed.setOnImagesAvailable { secondWakes.increment() }

        feed.noteVisibleDemand()
        await feed.requestPriority(uid, priority: .visibleNow)

        try await Self.waitUntil { firstWakes.value() > 0 && secondWakes.value() > 0 }
        #expect(firstWakes.value() > 0)
        #expect(secondWakes.value() > 0)
        #expect(await loader.fetched(uid))

        firstRegistration.end()
        secondRegistration.end()
    }

    @Test func endingOneWakeRegistrationLeavesTheOtherSubscriber() async throws {
        let uid = Self.uid("wake-end-one")
        let cache = Self.cache("wake-end-one")
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache, loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )
        let firstWakes = Counter()
        let secondWakes = Counter()
        let firstRegistration = await feed.setOnImagesAvailable { firstWakes.increment() }
        let secondRegistration = await feed.setOnImagesAvailable { secondWakes.increment() }
        firstRegistration.end()

        feed.noteVisibleDemand()
        await feed.requestPriority(uid, priority: .visibleNow)

        try await Self.waitUntil { secondWakes.value() > 0 }
        #expect(firstWakes.value() == 0)
        #expect(secondWakes.value() > 0)
        #expect(await loader.fetched(uid))

        secondRegistration.end()
    }

    @Test func backgroundCrawlDeliveryDoesNotWakeHostWithoutDemand() async throws {
        // A purely background crawl (no live viewport) must not spin the host's display loop: the wake stays
        // silent when there has been no recent visible demand.
        let uid = Self.uid("wake-idle")
        let cache = Self.cache("wake-idle")
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache, loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )
        let wakes = Counter()
        let registration = await feed.setOnImagesAvailable { wakes.increment() }

        await feed.startPrefetch([uid])  // crawl only; never sets visible demand
        try await Self.waitUntil { await loader.fetched(uid) }
        try await Task.sleep(for: .milliseconds(120))  // give any (erroneous) wake time to fire
        #expect(wakes.value() == 0)
        registration.end()
    }

    @Test func backgroundCrawlDeliveryWakesCacheConsumersWithoutViewportDemand() async throws {
        let uid = Self.uid("cache-wake-idle")
        let cache = Self.cache("cache-wake-idle")
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache, loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )
        let wakes = Counter()
        let registration = feed.setOnCacheArrivalWake { wakes.increment() }

        await feed.startPrefetch([uid])
        try await Self.waitUntil { wakes.value() > 0 }
        #expect(cache.hasUsableDiskData(uid))
        registration.end()
    }

    @Test func visiblePressureExcludesSequentialBacklogButTracksLiveDemand() async throws {
        // The Map's GPS crawl yields on `hasVisibleThumbnailPressure`. A pending whole-library sequential
        // A sequential fill must not count as pressure. The GPS crawl checks `hasPendingThumbnailWork`,
        // and the map remains responsive while the backlog is cached.
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let uids = (0..<8).map { Self.uid("pressure-\($0)") }
        let loader = RecordingLoader(delayMilliseconds: 250)
        let feed = ThumbnailFeedCore(
            cache: Self.cache("pressure"), loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1),
            clock: { clock.read() }
        )

        await feed.startPrefetch(uids)  // seeds the whole-library sequential backlog
        #expect(await feed.hasPendingThumbnailWork(), "sequential backlog must count as pending work")
        #expect(
            await feed.hasVisibleThumbnailPressure() == false,
            "a background fill alone must NOT register as visible pressure")

        feed.noteVisibleDemand()  // a live viewport appears
        #expect(await feed.hasVisibleThumbnailPressure(), "live demand must register as visible pressure")

        clock.advance(10)  // demand window (2 s) expires
        #expect(
            await feed.hasVisibleThumbnailPressure() == false,
            "expired demand must release the pressure so the GPS crawl resumes")
    }

    @Test func queuedVisibleThumbnailDoesNotMasqueradeAsActiveUserInteraction() async throws {
        let uid = Self.uid("stalled-visible")
        let feed = ThumbnailFeedCore(
            cache: Self.cache("stalled-visible"),
            loader: RecordingLoader(delayMilliseconds: 10_000),
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.requestPriority(uid, priority: .visibleNow)
        #expect(
            await feed.hasVisibleThumbnailPressure(),
            "the pending visible thumbnail remains important to the media scheduler")
        #expect(
            feed.hasActiveUserInteraction() == false,
            "a queued or stalled thumbnail must not indefinitely block unrelated background work")

        let grid = ThumbnailInteractionOwner()
        feed.setUserInteractionActive(true, owner: grid)
        #expect(feed.hasActiveUserInteraction())
        feed.setUserInteractionActive(false, owner: grid)
        #expect(feed.hasActiveUserInteraction() == false)
        await feed.stopPrefetch()
    }

    /// Several windows scroll one shared feed. The aggregate must stay active while any grid still interacts,
    /// and a grid that stops, disconnects, or switches feeds must remove only its own contribution.
    @Test func sharedFeedAggregatesInteractionPerOwner() async throws {
        let feed = ThumbnailFeedCore(
            cache: Self.cache("owners"), loader: RecordingLoader(), configuration: Self.configuration())
        let gridA = ThumbnailInteractionOwner()
        let gridB = ThumbnailInteractionOwner()

        // Overlap: B stops first while A keeps scrolling.
        feed.setUserInteractionActive(true, owner: gridA)
        feed.setUserInteractionActive(true, owner: gridB)
        #expect(feed.activeUserInteractionOwnerCount() == 2)
        feed.setUserInteractionActive(false, owner: gridB)
        #expect(feed.hasActiveUserInteraction(), "A still scrolls after B stops")
        #expect(feed.activeUserInteractionOwnerCount() == 1)
        feed.setUserInteractionActive(false, owner: gridA)
        #expect(feed.hasActiveUserInteraction() == false)
        #expect(feed.activeUserInteractionOwnerCount() == 0)

        // Reverse completion order: A stops first while B keeps pinching.
        feed.setUserInteractionActive(true, owner: gridA)
        feed.setUserInteractionActive(true, owner: gridB)
        feed.setUserInteractionActive(false, owner: gridA)
        #expect(feed.hasActiveUserInteraction(), "B still pinches after A stops")
        feed.setUserInteractionActive(false, owner: gridB)
        #expect(feed.hasActiveUserInteraction() == false)

        // Repeated reports from one owner are idempotent; a stop for an unknown owner is a no-op.
        feed.setUserInteractionActive(true, owner: gridA)
        feed.setUserInteractionActive(true, owner: gridA)
        #expect(feed.activeUserInteractionOwnerCount() == 1)
        feed.setUserInteractionActive(false, owner: ThumbnailInteractionOwner())
        #expect(feed.hasActiveUserInteraction(), "a stranger cannot clear A")
        feed.setUserInteractionActive(false, owner: gridA)
        #expect(feed.activeUserInteractionOwnerCount() == 0)

        // Feed switch: a grid that moves to another feed while scrolling releases the old feed only.
        let otherFeed = ThumbnailFeedCore(
            cache: Self.cache("owners-other"), loader: RecordingLoader(), configuration: Self.configuration())
        feed.setUserInteractionActive(true, owner: gridA)
        feed.setUserInteractionActive(true, owner: gridB)
        feed.setUserInteractionActive(false, owner: gridA)
        otherFeed.setUserInteractionActive(true, owner: gridA)
        #expect(feed.hasActiveUserInteraction(), "B keeps the old feed active")
        #expect(otherFeed.activeUserInteractionOwnerCount() == 1)
        feed.setUserInteractionActive(false, owner: gridB)
        otherFeed.setUserInteractionActive(false, owner: gridA)
        #expect(feed.hasActiveUserInteraction() == false)
        #expect(otherFeed.hasActiveUserInteraction() == false)
        await feed.stopPrefetch()
        await otherFeed.stopPrefetch()
    }

    @Test func corruptDiskBlobDoesNotStarveVisibleFetch() async throws {
        let cache = Self.cache("corrupt")
        let uid = Self.uid("corrupt")
        try Data(repeating: 0x09, count: 64).write(to: cache.diskURL(for: uid))
        #expect(cache.has(uid))

        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.requestPriority(uid, priority: .visibleNow)
        try await Self.waitUntil { await loader.fetched(uid) }
        #expect(await loader.fetched(uid))
        #expect(cache.hasUsableDiskData(uid))
    }

    @Test func platformPolicyIsInjectedThroughSanitizedConfiguration() {
        let configuration = ThumbnailFeedCoreConfiguration(
            targetPixels: -10,
            downloadConcurrencyLimit: 0,
            initialDownloadConcurrency: 99,
            minimumDownloadConcurrency: 0,
            batchSize: 0,
            decodedMemoryBudgetBytes: 0,
            maxConcurrentDecodes: 0,
            priorityQueueLimit: 0,
            sequentialScanLimit: 0,
            visibleQuietWindow: -1,
            crawlBackoffSeconds: -1,
            downloadTimeoutSeconds: 0
        )

        #expect(configuration.targetPixels == 1)
        #expect(configuration.downloadConcurrencyLimit == 1)
        #expect(configuration.initialDownloadConcurrency == 1)
        #expect(configuration.minimumDownloadConcurrency == 1)
        #expect(configuration.batchSize == 1)
        #expect(configuration.decodedMemoryBudgetBytes == 1)
        #expect(configuration.maxConcurrentDecodes == 1)
        #expect(configuration.priorityQueueLimit == 1)
        #expect(configuration.sequentialScanLimit == 1)
        #expect(configuration.visibleQuietWindow == 0)
        #expect(configuration.crawlBackoffSeconds == 0)
        #expect(configuration.downloadTimeoutSeconds == 0.1)
    }

    @Test func batchLoaderCompletesAllRequestedThumbnails() async throws {
        let uids = (0..<3).map { Self.uid("full-\($0)") }
        let cache = Self.cache("full")
        let loader = RecordingLoader(
            payloads: Dictionary(uniqueKeysWithValues: uids.map { ($0, Self.pngData(width: 8, height: 8)) }))
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration(batchSize: 4))

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await feed.prefetchStatus().downloadCompleted == 3 }

        let status = await feed.prefetchStatus()
        #expect(status.downloadStarted == 3)
        #expect(status.downloadCompleted == 3)
        #expect(status.failed == 0)
        #expect(uids.allSatisfy { cache.has($0) })
    }

    @Test func partialBatchCountsCompletedVersusFailed() async throws {
        let served = (0..<2).map { Self.uid("part-ok-\($0)") }
        let refused = (0..<2).map { Self.uid("part-no-\($0)") }
        let cache = Self.cache("partial")
        let loader = RecordingLoader(
            payloads: Dictionary(uniqueKeysWithValues: served.map { ($0, Self.pngData(width: 8, height: 8)) }),
            itemErrors: Dictionary(uniqueKeysWithValues: refused.map { ($0, "no thumbnail for node") })
        )
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration(batchSize: 4))

        await feed.startPrefetch(served + refused)
        try await Self.waitUntil {
            let status = await feed.prefetchStatus()
            return status.downloadCompleted == 2 && status.failed == 2
        }

        let status = await feed.prefetchStatus()
        #expect(status.downloadStarted == 4)
        #expect(status.downloadCompleted == 2)
        #expect(status.failed == 2)
        #expect(status.failedItemError == 2)
        #expect(status.failedTimeout == 0)
        #expect(status.failedBatchError == 0)
        #expect(status.unfetchableCount == 2)
        #expect(status.lastErrors.joined().contains("no thumbnail for node"))
    }

    @Test func zeroResultBatchRecordsClassifiedFailureAndBacksOff() async throws {
        let uids = (0..<2).map { Self.uid("zero-\($0)") }
        let frozen = Date(timeIntervalSince1970: 5000)
        let loader = RecordingLoader(batchError: "simulated 429")
        let feed = ThumbnailFeedCore(
            cache: Self.cache("zero"),
            loader: loader,
            configuration: Self.configuration(batchSize: 2),
            clock: { frozen }
        )

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await feed.prefetchStatus().failedBatchError == 2 }

        // With a frozen clock, the crawl backoff never expires; no further attempts may happen.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await loader.requestCount() == 2)

        let status = await feed.prefetchStatus()
        #expect(status.downloadStarted == 2)
        #expect(status.downloadCompleted == 0)
        #expect(status.failed == 2)
        #expect(status.failedBatchError == 2)
        #expect(status.lastErrors.joined().contains("simulated 429"))
        await feed.stopPrefetch()  // frozen clock never expires the backoff; don't leave the worker looping
    }

    #if DEBUG
        @Test func endOfCrawlCoverageRescanIsBoundedNotFullLibraryScan() async throws {
            // Concurrency invariant: a single end-of-crawl coverage step stats only a bounded chunk, never the
            // whole library, so no worker (and not the whole stampede of them) can hold the serial feed actor for
            // an O(library) scan that would starve a visible warm decode. Proven directly on the incremental scan.
            let feed = ThumbnailFeedCore(
                cache: Self.cache("coverage-bound"), loader: RecordingLoader(), configuration: Self.configuration())
            let library = (0..<5000).map { Self.uid("cov-\($0)") }

            let statsInOneStep = await feed.coverageScanStepStatCountForTesting(seeding: library)

            #expect(statsInOneStep < library.count)  // one actor-held step never scans the whole 5000-item library
            #expect(statsInOneStep == 512)  // it advances exactly one bounded chunk
        }

        @Test func coverageScanAbortsImmediatelyWhenViewportIsLive() async throws {
            // A live viewport aborts the coverage re-scan before it stats a single item, so a visible warm decode is
            // never blocked behind coverage maintenance. With a frozen clock, the demand stays "recent".
            let frozen = Date(timeIntervalSince1970: 5000)
            let feed = ThumbnailFeedCore(
                cache: Self.cache("coverage-abort"), loader: RecordingLoader(),
                configuration: Self.configuration(), clock: { frozen })
            feed.noteVisibleDemand()  // synchronous (nonisolated); frozen clock keeps it recent
            let library = (0..<5000).map { Self.uid("abort-\($0)") }

            let scanned = await feed.coverageScanStepStatCountForTesting(seeding: library)

            #expect(scanned == 0)  // aborted before the first `cache.has` stat
        }

        @Test func endOfCrawlCoverageRefreshIsSingleFlightAndSkipsRedundantScan() async throws {
            // Many workers reach the drained end together, but the coverage refresh is single-flight: exactly one
            // runs. The crawl's per-item
            // `diskPresence` tracking already established full coverage during the drain, that one refresh settles
            // from the known state without a redundant full `cache.has` re-scan.
            let uids = (0..<40).map { Self.uid("single-flight-\($0)") }
            let cache = Self.cache("single-flight")
            let png = Self.pngData(width: 8, height: 8)
            for uid in uids { cache.storeToDisk(png, for: uid) }
            let feed = ThumbnailFeedCore(
                cache: cache, loader: RecordingLoader(),
                configuration: Self.configuration(downloadConcurrencyLimit: 8))

            await feed.startPrefetch(uids)
            try await Self.waitUntil { await feed.coverageRefreshStartCountForTesting() >= 1 }
            try await Task.sleep(for: .milliseconds(120))  // give any stampede a chance to (wrongly) start more

            #expect(await feed.coverageRefreshStartCountForTesting() == 1)  // one refresh, not one per worker
            #expect(await feed.coverageFullScanCountForTesting() == 0)  // Known state means no redundant full sweep.
            #expect(await feed.prefetchStatus().diskThumbnailCoverageFraction >= 1.0)  // and coverage is correct
            await feed.stopPrefetch()
        }

        @Test func coverageRefreshResumesAfterVisibleDemandQuiets() async throws {
            let clock = MutableClock(Date(timeIntervalSince1970: 1000))
            let uids = (0..<20).map { Self.uid("resume-\($0)") }
            let cache = Self.cache("coverage-resume")
            let png = Self.pngData(width: 8, height: 8)
            for uid in uids { cache.storeToDisk(png, for: uid) }
            let feed = ThumbnailFeedCore(
                cache: cache, loader: RecordingLoader(),
                configuration: Self.configuration(downloadConcurrencyLimit: 4),
                clock: { clock.read() })

            feed.noteVisibleDemand()  // The live viewport at T=1000 keeps coverage refresh gated.
            await feed.startPrefetch(uids)
            try await Task.sleep(for: .milliseconds(150))
            #expect(await feed.coverageRefreshStartCountForTesting() == 0)  // no refresh while demand is recent

            clock.advance(1.0)  // demand quiets
            try await Self.waitUntil { await feed.coverageRefreshStartCountForTesting() >= 1 }
            #expect(await feed.coverageRefreshStartCountForTesting() >= 1)  // coverage refresh resumes once idle
            await feed.stopPrefetch()
        }
    #endif

    @Test func decodedCacheHitAndMissKeyedByPhotoUID() {
        let cache = DecodedThumbnailCache(costLimit: 1_000_000)
        let a = Self.uid("dc-a")
        let b = Self.uid("dc-b")
        cache.set(Self.decodedThumb(10, 10), for: a, decodePixelCap: 320)
        #expect(cache.image(for: a) != nil)
        #expect(cache.image(for: b) == nil)
        #expect(cache.contains(a))
        #expect(!cache.contains(b))
    }

    #if DEBUG
        @Test func decodedCacheEvictsLruWhenOverBudgetAndKeepsRecentlyUsed() {
            // Budget holds exactly two 10×10×4=400-byte entries; the third eviction targets the LRU.
            let cache = DecodedThumbnailCache(costLimit: 800)
            let ids = (0..<3).map { Self.uid("dc-lru-\($0)") }
            cache.set(Self.decodedThumb(10, 10), for: ids[0], decodePixelCap: 320)
            cache.set(Self.decodedThumb(10, 10), for: ids[1], decodePixelCap: 320)
            // Touch the first item so the second becomes the eviction candidate.
            _ = cache.image(for: ids[0])
            cache.set(Self.decodedThumb(10, 10), for: ids[2], decodePixelCap: 320)

            #expect(cache.image(for: ids[0]) != nil)  // recently used survives
            #expect(cache.image(for: ids[1]) == nil)  // least-recently used evicted
            #expect(cache.image(for: ids[2]) != nil)  // just-inserted survives
            #expect(cache.snapshotForTesting().count == 2)
        }

        @Test func decodedCacheReplaceUpdatesRunningCost() {
            let cache = DecodedThumbnailCache(costLimit: 10_000_000)
            let a = Self.uid("dc-rep")
            cache.set(Self.decodedThumb(10, 10), for: a, decodePixelCap: 320)  // 400
            #expect(cache.snapshotForTesting().cost == 400)
            cache.set(Self.decodedThumb(20, 20), for: a, decodePixelCap: 320)
            #expect(cache.snapshotForTesting().count == 1)
            #expect(cache.snapshotForTesting().cost == 1600)
        }

        @Test func decodedCacheKeepsSingleOverBudgetItemThenReclaims() {
            // An item alone larger than the whole budget is kept (transiently over budget), then reclaimed
            // when a newer item arrives.
            let cache = DecodedThumbnailCache(costLimit: 100)
            let a = Self.uid("dc-big-a")
            cache.set(Self.decodedThumb(10, 10), for: a, decodePixelCap: 320)  // 400 > 100, so the entry is kept.
            #expect(cache.image(for: a) != nil)
            #expect(cache.snapshotForTesting().count == 1)
            let b = Self.uid("dc-big-b")
            cache.set(Self.decodedThumb(10, 10), for: b, decodePixelCap: 320)  // Keeping b evicts the LRU (a).
            #expect(cache.image(for: b) != nil)
            #expect(cache.image(for: a) == nil)
        }

        @Test func decodedCacheSetCostLimitEvictsDownToBudget() {
            let cache = DecodedThumbnailCache(costLimit: 10_000_000)
            let ids = (0..<3).map { Self.uid("dc-shrink-\($0)") }
            for id in ids { cache.set(Self.decodedThumb(10, 10), for: id, decodePixelCap: 320) }  // 3×400 = 1200
            cache.setCostLimit(800)  // shrink to evict oldest down to ≤800
            #expect(cache.snapshotForTesting().count == 2)
            #expect(cache.snapshotForTesting().cost <= 800)
            #expect(cache.image(for: ids[2]) != nil)  // newest survives
            #expect(cache.image(for: ids[0]) == nil)  // oldest evicted
        }

        @Test func decodedCacheRemoveAllClears() {
            let cache = DecodedThumbnailCache(costLimit: 10_000_000)
            cache.set(Self.decodedThumb(10, 10), for: Self.uid("dc-x"), decodePixelCap: 320)
            cache.removeAll()
            #expect(cache.snapshotForTesting().count == 0)
            #expect(cache.snapshotForTesting().cost == 0)
            #expect(cache.image(for: Self.uid("dc-x")) == nil)
        }
    #endif

    @Test func visibleDiskDemandBeforeAuthorizationRecoversWithoutAnotherViewport() async throws {
        let old = Self.uid("old-viewport")
        let visible = Self.uid("initial-viewport")
        let cache = Self.cache("visible-before-authorization")
        let payload = Self.pngData(width: 8, height: 8)
        cache.storeToDisk(payload, for: old)
        cache.storeToDisk(payload, for: visible)
        let loader = RecordingLoader()
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration())
        await feed.setPrefetchEnabled(false)
        let graph = LibrarySourceGraph()
        let change = Self.visibleScope(in: graph, uids: [old, visible])
        #expect(await feed.bindDerivedDataEpoch(graph.runtimeEpoch))

        feed.submitVisibleDiskDecodeDemand([ThumbnailRequest(uid: old)])
        feed.submitVisibleDiskDecodeDemand([ThumbnailRequest(uid: visible)])
        try await Task.sleep(for: .milliseconds(100))
        #expect(feed.memoryDecoded(for: visible) == nil, "pending authorization must remain fail-closed")
        _ = await feed.reconcile(
            selected: change.selectedScope, analysis: change.analysisScope,
            retention: change.thumbnailRetentionScope)
        try await Self.waitUntil { feed.memoryDecoded(for: visible) != nil }
        #expect(feed.memoryDecoded(for: visible) != nil, "no second submit or scroll is allowed for recovery")
        #expect(feed.memoryDecoded(for: old) == nil, "only the newest viewport is replayed")
        #expect(await loader.requestCount() == 0, "this must be viewport disk decoding, not a crawl")
        await feed.stopPrefetchAndWait()
    }

    @Test func unchangedVisibleDemandRetriesAfterMemoryPressure() async throws {
        let uid = Self.uid("visible-after-memory-pressure")
        let cache = Self.cache("visible-after-memory-pressure")
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: uid)
        let feed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(), configuration: Self.configuration())
        let requests = [ThumbnailRequest(uid: uid)]
        feed.submitVisibleDiskDecodeDemand(requests)
        try await Self.waitUntil { feed.memoryDecoded(for: uid) != nil }
        #expect(feed.memoryDecoded(for: uid) != nil)
        // The host has not yet submitted a smaller missing set when pressure removes these decoded tiles.
        feed.applyDecodedMemoryPressure(scale: 1, purge: true)
        #expect(feed.memoryDecoded(for: uid) == nil)
        feed.submitVisibleDiskDecodeDemand(requests)
        try await Self.waitUntil { feed.memoryDecoded(for: uid) != nil }
        #expect(feed.memoryDecoded(for: uid) != nil, "equal viewport demand must recover after eviction")
        await feed.stopPrefetchAndWait()
    }

    @Test func stoppedVisibleDemandIsNotReplayedBySourceAdmission() async throws {
        let uid = Self.uid("stopped-viewport")
        let cache = Self.cache("stopped-before-authorization")
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: uid)
        let loader = RecordingLoader()
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration())
        await feed.setPrefetchEnabled(false)
        let graph = LibrarySourceGraph()
        let change = Self.visibleScope(in: graph, uids: [uid])
        #expect(await feed.bindDerivedDataEpoch(graph.runtimeEpoch))
        feed.submitVisibleDiskDecodeDemand([ThumbnailRequest(uid: uid)])
        _ = await feed.replaceVisiblePriorityDemand([uid])
        await feed.stopPrefetchAndWait()
        _ = await feed.reconcile(
            selected: change.selectedScope, analysis: change.analysisScope,
            retention: change.thumbnailRetentionScope)
        try await Task.sleep(for: .milliseconds(150))
        #expect(feed.memoryDecoded(for: uid) == nil)
        #expect(await loader.requestCount() == 0)
        await feed.stopPrefetchAndWait()
    }

    @Test(arguments: [true, false])
    func visibleNetworkDemandBeforeAuthorizationRecoversAndDecodesArrival(includedInLibrary: Bool) async throws {
        let uid = Self.uid("visible-network-before-scope")
        let cache = Self.cache("visible-network-before-scope")
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration())
        // Pause only speculative crawling. Disabling prefetch also fences network disk probes, so it
        // cannot exercise the supported visible-network path.
        await feed.pausePrefetch()
        let graph = LibrarySourceGraph()
        let change = Self.visibleScope(in: graph, uids: [uid], includedInLibrary: includedInLibrary)
        #expect(await feed.bindDerivedDataEpoch(graph.runtimeEpoch))
        feed.submitVisibleDiskDecodeDemand([ThumbnailRequest(uid: uid)])
        #expect(await feed.replaceVisiblePriorityDemand([uid]) == 0)
        #expect(await loader.requestCount() == 0)
        _ = await feed.reconcile(
            selected: change.selectedScope, analysis: change.analysisScope,
            retention: change.thumbnailRetentionScope)
        try await Self.waitUntil { feed.memoryDecoded(for: uid) != nil }
        #expect(feed.memoryDecoded(for: uid) != nil, "a disk miss must recover without a second stable viewport")
        let requestCount = await loader.requestCount()
        #expect(requestCount == 1)
        await feed.stopPrefetchAndWait()
    }

    @Test(arguments: [true, false])
    func sourceAdmissionWakesAwaitedVisibleWarmPath(includedInLibrary: Bool) async throws {
        let uid = Self.uid("awaited-visible-before-scope")
        let cache = Self.cache("awaited-visible-before-scope")
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: uid)
        let loader = RecordingLoader()
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration())
        await feed.setPrefetchEnabled(false)
        let graph = LibrarySourceGraph()
        let change = Self.visibleScope(in: graph, uids: [uid], includedInLibrary: includedInLibrary)
        #expect(await feed.bindDerivedDataEpoch(graph.runtimeEpoch))
        let requests = [ThumbnailRequest(uid: uid)]
        let blocked = await feed.warmVisibleDecoded(requests, limit: 1)
        #expect(blocked.requested == 0)
        let wakes = Counter()
        let registration = feed.setOnImagesAvailableWake { wakes.increment() }
        defer { registration.end() }
        _ = await feed.reconcile(
            selected: change.selectedScope, analysis: change.analysisScope,
            retention: change.thumbnailRetentionScope)
        #expect(wakes.value() == 1, "UIKit's existing arrival hook must schedule a new awaited warm pass")
        let admitted = await feed.warmVisibleDecoded(requests, limit: 1)
        #expect(admitted.decodedFromDisk == 1)
        #expect(feed.memoryDecoded(for: uid) != nil)
        #expect(await loader.requestCount() == 0)
        await feed.stopPrefetchAndWait()
    }

    @Test func burstFilmstripMembersAreReadableAlthoughTheyAreNotLibraryItems() async throws {
        let key = Self.uid("burst-key")
        let member = Self.uid("burst-member")
        let cache = Self.cache("burst-member-read")
        let loader = RecordingLoader(payloads: [member: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration())
        await feed.setPrefetchEnabled(false)
        let graph = LibrarySourceGraph()
        let source = LibrarySource(id: SourceID("burst-test"), capabilities: .readThumbnail, isIncluded: true)
        _ = graph.commitSourceSet([source], using: graph.beginSourceSetRefresh())
        let keyItem = PhotoItem(
            uid: key,
            captureTime: Date(timeIntervalSince1970: 0),
            mediaType: "image/jpeg",
            burstMemberIDs: [key.nodeID, member.nodeID]
        )
        let change = try #require(
            graph.commit([.complete(keyItem)], validationToken: nil, using: graph.beginRefresh(source.id)!))
        // A burst member belongs to the thumbnail retention scope, not to the analysis scope.
        #expect(!change.analysisScope.uids.contains(member))
        #expect(change.thumbnailRetentionScope.uids.contains(member))
        #expect(await feed.bindDerivedDataEpoch(graph.runtimeEpoch))
        _ = await feed.reconcile(
            selected: change.selectedScope, analysis: change.analysisScope,
            retention: change.thumbnailRetentionScope)

        #expect(await feed.decoded(for: member) != nil, "an opened series must load its member thumbnails")
        #expect(feed.memoryDecoded(for: member) != nil)
        #expect(await loader.requestCount() == 1)
        await feed.stopPrefetchAndWait()
    }

    @Test func recentlyDeletedPhotosAreReadableAlthoughNoInventoryListsThem() async throws {
        let item = Self.uid("library-item")
        let trashed = Self.uid("trashed-photo")
        let cache = Self.cache("trash-read")
        let payload = Self.pngData(width: 8, height: 8)
        let loader = RecordingLoader(payloads: [item: payload, trashed: payload])
        // One worker and single-item batches keep the loader's call order equal to the crawl order.
        let feed = ThumbnailFeedCore(
            cache: cache, loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1))
        let graph = LibrarySourceGraph()
        let source = LibrarySource(id: SourceID("trash-test"), capabilities: .readThumbnail, isIncluded: true)
        _ = graph.commitSourceSet([source], using: graph.beginSourceSetRefresh())
        let libraryItem = PhotoItem(
            uid: item, captureTime: Date(timeIntervalSince1970: 0), mediaType: "image/jpeg")
        _ = graph.commit([.complete(libraryItem)], validationToken: nil, using: graph.beginRefresh(source.id)!)
        // The trash listing registers what Recently Deleted shows.
        let change = try #require(graph.setIdentitiesOutsideInventory([trashed]))
        #expect(change.thumbnailRetentionScope.uids.contains(trashed))
        #expect(change.thumbnailRetentionScope.authorizationOnlyUIDs == [trashed])
        #expect(
            !change.thumbnailRetentionScope.orderedUIDs.contains(trashed),
            "a trashed photo must stay out of every analysis and relationship order")
        #expect(await feed.bindDerivedDataEpoch(graph.runtimeEpoch))
        _ = await feed.reconcile(
            selected: change.selectedScope, analysis: change.analysisScope,
            retention: change.thumbnailRetentionScope)

        #expect(await feed.decoded(for: trashed) != nil, "a Recently Deleted tile must show its thumbnail")
        #expect(feed.memoryDecoded(for: trashed) != nil)
        await feed.stopPrefetchAndWait()
    }

    @Test func leavingRecentlyDeletedWithdrawsItsThumbnailAuthorization() async throws {
        let trashed = Self.uid("trashed-photo-withdrawn")
        let cache = Self.cache("trash-withdraw")
        let loader = RecordingLoader(payloads: [trashed: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration())
        await feed.setPrefetchEnabled(false)
        let graph = LibrarySourceGraph()
        let source = LibrarySource(id: SourceID("trash-test"), capabilities: .readThumbnail, isIncluded: true)
        _ = graph.commitSourceSet([source], using: graph.beginSourceSetRefresh())
        _ = graph.commit([], validationToken: nil, using: graph.beginRefresh(source.id)!)
        let registered = try #require(graph.setIdentitiesOutsideInventory([trashed]))
        #expect(await feed.bindDerivedDataEpoch(graph.runtimeEpoch))
        _ = await feed.reconcile(
            selected: registered.selectedScope, analysis: registered.analysisScope,
            retention: registered.thumbnailRetentionScope)
        #expect(await feed.decoded(for: trashed) != nil)

        let cleared = try #require(graph.setIdentitiesOutsideInventory([]))
        _ = await feed.reconcile(
            selected: cleared.selectedScope, analysis: cleared.analysisScope,
            retention: cleared.thumbnailRetentionScope)

        #expect(await feed.decoded(for: trashed) == nil, "the route no longer shows this photo")
        await feed.stopPrefetchAndWait()
    }

    @Test func burstMembersAreCrawledToDiskAfterEveryLibraryThumbnail() async throws {
        let key = Self.uid("crawl-burst-key")
        let other = Self.uid("crawl-library-item")
        let members = [Self.uid("crawl-burst-member-1"), Self.uid("crawl-burst-member-2")]
        let cache = Self.cache("burst-member-crawl")
        let payload = Self.pngData(width: 8, height: 8)
        let payloads = Dictionary(uniqueKeysWithValues: ([key, other] + members).map { ($0, payload) })
        let loader = RecordingLoader(payloads: payloads)
        // One worker and single-item batches keep the loader's call order equal to the crawl order.
        let feed = ThumbnailFeedCore(
            cache: cache, loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1))
        let graph = LibrarySourceGraph()
        let source = LibrarySource(id: SourceID("burst-crawl"), capabilities: .readThumbnail, isIncluded: true)
        _ = graph.commitSourceSet([source], using: graph.beginSourceSetRefresh())
        let items: [LibrarySourceItem] = [
            .complete(
                PhotoItem(
                    uid: key,
                    captureTime: Date(timeIntervalSince1970: 2),
                    mediaType: "image/jpeg",
                    burstMemberIDs: [key.nodeID] + members.map(\.nodeID)
                )),
            .complete(PhotoItem(uid: other, captureTime: Date(timeIntervalSince1970: 1), mediaType: "image/jpeg")),
        ]
        let change = try #require(graph.commit(items, validationToken: nil, using: graph.beginRefresh(source.id)!))
        #expect(await feed.bindDerivedDataEpoch(graph.runtimeEpoch))

        _ = await feed.reconcile(
            selected: change.selectedScope, analysis: change.analysisScope,
            retention: change.thumbnailRetentionScope)
        try await Self.waitUntil { members.allSatisfy { cache.diskData(for: $0) != nil } }

        let order = await loader.requestOrder()
        let lastLibraryRequest = try #require([key, other].compactMap { order.firstIndex(of: $0) }.max())
        for member in members {
            let memberRequest = try #require(order.firstIndex(of: member))
            #expect(memberRequest > lastLibraryRequest, "burst members follow every library thumbnail")
        }
        await feed.stopPrefetchAndWait()
    }

    @Test func recentlyDeletedThumbnailsAreCrawledAfterEveryLibraryThumbnail() async throws {
        let library = [Self.uid("trash-crawl-library-1"), Self.uid("trash-crawl-library-2")]
        let newerTrashed = Self.uid("trash-crawl-newer")
        let olderTrashed = Self.uid("trash-crawl-older")
        let cache = Self.cache("trash-crawl")
        let payload = Self.pngData(width: 8, height: 8)
        let payloads = Dictionary(
            uniqueKeysWithValues: (library + [newerTrashed, olderTrashed]).map { ($0, payload) })
        let loader = RecordingLoader(payloads: payloads)
        // One worker and single-item batches keep the loader's call order equal to the crawl order.
        let feed = ThumbnailFeedCore(
            cache: cache, loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1))
        let graph = LibrarySourceGraph()
        let source = LibrarySource(id: SourceID("trash-crawl"), capabilities: .readThumbnail, isIncluded: true)
        _ = graph.commitSourceSet([source], using: graph.beginSourceSetRefresh())
        _ = graph.commit(Self.sourceItems(library), validationToken: nil, using: graph.beginRefresh(source.id)!)
        // The trash listing registers Recently Deleted newest first; a library photo in it is not duplicated.
        let change = try #require(graph.setIdentitiesOutsideInventory([newerTrashed, library[0], olderTrashed]))
        #expect(change.thumbnailRetentionScope.authorizationOnlyOrder == [newerTrashed, olderTrashed])
        #expect(await feed.bindDerivedDataEpoch(graph.runtimeEpoch))

        _ = await feed.reconcile(
            selected: change.selectedScope, analysis: change.analysisScope,
            retention: change.thumbnailRetentionScope)
        try await Self.waitUntil { [newerTrashed, olderTrashed].allSatisfy { cache.diskData(for: $0) != nil } }

        let order = await loader.requestOrder()
        let lastLibraryRequest = try #require(library.compactMap { order.firstIndex(of: $0) }.max())
        let newerRequest = try #require(order.firstIndex(of: newerTrashed))
        let olderRequest = try #require(order.firstIndex(of: olderTrashed))
        #expect(newerRequest > lastLibraryRequest, "Recently Deleted follows every library thumbnail")
        #expect(olderRequest > newerRequest, "Recently Deleted is crawled newest first")
        #expect(!change.analysisScope.uids.contains(newerTrashed), "no analysis reads a trashed photo")
        await feed.stopPrefetchAndWait()
    }

    private static func visibleScope(
        in graph: LibrarySourceGraph, uids: [PhotoUID], includedInLibrary: Bool = true
    ) -> LibrarySourceChange {
        let source = LibrarySource(
            id: SourceID("visible-demand-test"), capabilities: .readThumbnail, isIncluded: includedInLibrary)
        _ = graph.commitSourceSet([source], using: graph.beginSourceSetRefresh())
        return graph.commit(Self.sourceItems(uids), validationToken: nil, using: graph.beginRefresh(source.id)!)!
    }

    @Test func feedScopeReplacementPurgesDecodedAndEncryptedTiers() async {
        let retained = Self.uid("feed-retained-membership")
        let orphaned = Self.uid("feed-final-orphan")
        let cache = Self.cache("feed-source-removal")
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: retained)
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: orphaned)
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: RecordingLoader(),
            configuration: Self.configuration()
        )
        #expect(await feed.cachedDecoded(for: retained) != nil)
        #expect(await feed.cachedDecoded(for: orphaned) != nil)
        // Retained viewport intent must not re-authorize an asset when its final membership is revoked.
        feed.submitVisibleDiskDecodeDemand([
            ThumbnailRequest(uid: retained), ThumbnailRequest(uid: orphaned),
        ])
        _ = await feed.replaceVisiblePriorityDemand([retained, orphaned])
        let source = LibrarySource(
            id: SourceID("feed-source"),
            capabilities: .readThumbnail
        )
        let graph = LibrarySourceGraph()
        let sourceSetLease = graph.beginSourceSetRefresh()
        _ = graph.commitSourceSet([source], using: sourceSetLease)
        let initialRefresh = graph.beginRefresh(source.id)!
        _ = graph.commit(
            Self.sourceItems([retained, orphaned]),
            validationToken: nil,
            using: initialRefresh
        )
        let replacementRefresh = graph.beginRefresh(source.id)!
        let replacement = graph.commit(
            Self.sourceItems([retained]),
            validationToken: nil,
            using: replacementRefresh
        )!
        #expect(await feed.bindDerivedDataEpoch(graph.runtimeEpoch))

        let result = await feed.reconcile(
            selected: replacement.selectedScope,
            analysis: replacement.analysisScope,
            retention: replacement.thumbnailRetentionScope
        )

        #expect(result == .reconciled(removedEntries: 1))
        #expect(feed.memoryDecoded(for: retained) != nil)
        #expect(feed.memoryDecoded(for: orphaned) == nil)
        #expect(await feed.cachedDecoded(for: retained) != nil)
        #expect(cache.diskData(for: retained) != nil)
        #expect(cache.diskData(for: orphaned) == nil)
        await feed.stopPrefetchAndWait()
    }

    @Test func analysisOnlyInventoryIsIndexedAndRetainedWithoutEnteringVisibleCoverage() async throws {
        let primaryUID = Self.uid("feed-primary")
        let analysisUID = Self.uid("feed-analysis-only")
        let payload = Self.pngData(width: 8, height: 8)
        let loader = RecordingLoader(payloads: [primaryUID: payload, analysisUID: payload])
        let cache = Self.cache("feed-analysis-scope")
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 2)
        )
        let primarySource = LibrarySource(
            id: SourceID("primary-source"),
            capabilities: .readThumbnail
        )
        let analysisSource = LibrarySource(
            id: SourceID("analysis-source"),
            capabilities: .readThumbnail,
            isIncluded: false
        )
        let graph = LibrarySourceGraph()
        let sourceSetLease = graph.beginSourceSetRefresh()
        _ = graph.commitSourceSet([primarySource, analysisSource], using: sourceSetLease)
        let primaryRefresh = graph.beginRefresh(primarySource.id)!
        _ = graph.commit(Self.sourceItems([primaryUID]), validationToken: nil, using: primaryRefresh)
        let analysisRefresh = graph.beginRefresh(analysisSource.id)!
        let change = graph.commit(
            Self.sourceItems([analysisUID]),
            validationToken: nil,
            using: analysisRefresh
        )!
        #expect(await feed.bindDerivedDataEpoch(graph.runtimeEpoch))

        _ = await feed.reconcile(
            selected: change.selectedScope,
            analysis: change.analysisScope,
            retention: change.thumbnailRetentionScope
        )
        try await Self.waitUntil {
            let status = await feed.prefetchStatus()
            let requestCount = await loader.requestCount()
            return status.diskCoverageVerified && requestCount >= 2
        }

        let status = await feed.prefetchStatus()
        #expect(status.diskThumbnailTotal == 1)
        #expect(status.diskFileCount == 1)
        #expect(status.downloadCompleted == 1)
        #expect(cache.diskFileCount() == 2)
        #expect(feed.memoryDecoded(for: analysisUID) == nil, "the background crawl must not decode into the grid LRU")
        #expect(await feed.backgroundCachedDecoded(for: analysisUID) != nil)
        #expect(feed.memoryDecoded(for: analysisUID) == nil, "background analysis must remain cache-only")
        #expect(
            await feed.cachedDecoded(for: analysisUID) != nil, "an opened shared album can display its cached tiles")
        #expect(feed.memoryDecoded(for: analysisUID) != nil)

        let replacementLease = graph.beginSourceSetRefresh()
        let replacement = graph.commitSourceSet([primarySource], using: replacementLease)!
        _ = await feed.reconcile(
            selected: replacement.selectedScope,
            analysis: replacement.analysisScope,
            retention: replacement.thumbnailRetentionScope
        )
        #expect(cache.diskData(for: primaryUID) != nil)
        #expect(cache.diskData(for: analysisUID) == nil)
        #expect(await feed.backgroundCachedDecoded(for: analysisUID) == nil)
        #expect(feed.memoryDecoded(for: analysisUID) == nil)
        #expect(await feed.cachedDecoded(for: analysisUID) == nil)
        #expect(await feed.requestPriority(analysisUID) == false)
    }

    @Test func feedScopeReplacementCoalescesNewerRevisionDuringWorkerJoin() async throws {
        let original = Self.uid("feed-original-revision")
        let superseded = Self.uid("feed-superseded-revision")
        let latest = Self.uid("feed-latest-revision")
        let loader = ControlledLateLoader(payloads: [:])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("feed-source-reentrancy"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )
        let source = LibrarySource(
            id: SourceID("feed-reentrant-source"),
            capabilities: .readThumbnail
        )
        let graph = LibrarySourceGraph()
        let sourceSetLease = graph.beginSourceSetRefresh()
        _ = graph.commitSourceSet([source], using: sourceSetLease)
        let initialRefresh = graph.beginRefresh(source.id)!
        let initial = graph.commit(
            Self.sourceItems([original]),
            validationToken: nil,
            using: initialRefresh
        )!
        #expect(await feed.bindDerivedDataEpoch(graph.runtimeEpoch))
        _ = await feed.reconcile(
            selected: initial.selectedScope,
            analysis: initial.analysisScope,
            retention: initial.thumbnailRetentionScope
        )
        try await Self.waitUntil { await loader.isWaiting() }
        #expect(await loader.isWaiting())

        let supersededRefresh = graph.beginRefresh(source.id)!
        let supersededChange = graph.commit(
            Self.sourceItems([superseded]),
            validationToken: nil,
            using: supersededRefresh
        )!
        let joining = Task {
            await feed.reconcile(
                selected: supersededChange.selectedScope,
                analysis: supersededChange.analysisScope,
                retention: supersededChange.thumbnailRetentionScope
            )
        }
        try await Task.sleep(for: .milliseconds(50))

        let latestRefresh = graph.beginRefresh(source.id)!
        let latestChange = graph.commit(
            Self.sourceItems([latest]),
            validationToken: nil,
            using: latestRefresh
        )!
        let latestJoining = Task {
            await feed.reconcile(
                selected: latestChange.selectedScope,
                analysis: latestChange.analysisScope,
                retention: latestChange.thumbnailRetentionScope
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        await loader.release()
        let latestResult = await latestJoining.value
        let supersededResult = await joining.value
        try await Self.waitUntil { await loader.requestedOrder().contains(latest) }
        let requested = await loader.requestedOrder()

        #expect(latestResult != .staleScope)
        #expect(supersededResult == .staleScope)
        #expect(requested.contains(original))
        #expect(requested.contains(latest))
        #expect(!requested.contains(superseded))
        await feed.stopPrefetchAndWait()
    }

    @Test func warmReDecodesSharperWhenALargerPixelSizeIsRequested() async throws {
        // Decoded once small for a dense level, the same UID must re-decode sharper for a larger level -
        // "already decoded" is size-aware, keyed on the shared 1.25× upgrade hysteresis.
        let uid = Self.uid("upgrade")
        let cache = Self.cache("upgrade")
        cache.storeToDisk(Self.pngData(width: 64, height: 64), for: uid)
        let feed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(), configuration: Self.configuration())

        let small = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(small.decodedFromDisk == 1)
        #expect(feed.memoryDecoded(for: uid)?.pixelWidth == 16)  // configuration targetPixels = 16

        let sharpened = await feed.warmDecoded(
            [ThumbnailRequest(uid: uid, pixelSize: 64)], priority: .visibleNow, limit: 1)
        #expect(sharpened.alreadyDecoded == 0)
        #expect(sharpened.decodedFromDisk == 1)  // re-decoded, not skipped
        #expect(feed.memoryDecoded(for: uid)?.pixelWidth == 64)  // cached image actually got sharper
    }

    @Test func warmSkipsSlightlyLargerAsksWithoutChurn() async throws {
        // An ask below the 1.25× hysteresis (18 vs cap 16) must not re-decode - repeated settled frames at
        // a marginally different effective size stay free.
        let uid = Self.uid("no-churn")
        let cache = Self.cache("no-churn")
        cache.storeToDisk(Self.pngData(width: 64, height: 64), for: uid)
        let feed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(), configuration: Self.configuration())

        _ = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        for _ in 0..<3 {
            let again = await feed.warmDecoded(
                [ThumbnailRequest(uid: uid, pixelSize: 18)], priority: .visibleNow, limit: 1)
            #expect(again.alreadyDecoded == 1)
            #expect(again.decodedFromDisk == 0)
        }
        #expect(feed.memoryDecoded(for: uid)?.pixelWidth == 16)
    }

    @Test func sourceLimitedImageNeverReDecodesInALoop() async throws {
        // The recorded decode cap (not the achieved size) gates adequacy: a 64 px source asked for at 320
        // yields a 64 px image, and repeating the 320 ask must be a no-op, not a per-frame re-decode.
        let uid = Self.uid("src-limited")
        let cache = Self.cache("src-limited")
        cache.storeToDisk(Self.pngData(width: 64, height: 64), for: uid)
        let feed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(), configuration: Self.configuration())

        let first = await feed.warmDecoded(
            [ThumbnailRequest(uid: uid, pixelSize: 320)], priority: .visibleNow, limit: 1)
        #expect(first.decodedFromDisk == 1)
        #expect(feed.memoryDecoded(for: uid)?.pixelWidth == 64)  // source-limited below the 320 ask

        for _ in 0..<3 {
            let again = await feed.warmDecoded(
                [ThumbnailRequest(uid: uid, pixelSize: 320)], priority: .visibleNow, limit: 1)
            #expect(again.alreadyDecoded == 1)
            #expect(again.decodedFromDisk == 0)
        }
        // And the render loop's retry signal agrees: nothing sharper is available for this ask.
        #expect(!feed.decodedNeedsSharperSource(uid, forPixels: 320))
    }

    @Test func decodedNeedsSharperSourceReportsOnlyPresentUndersizedEntries() async throws {
        let uid = Self.uid("sharper-signal")
        let cache = Self.cache("sharper-signal")
        cache.storeToDisk(Self.pngData(width: 64, height: 64), for: uid)
        let feed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(), configuration: Self.configuration())

        #expect(!feed.decodedNeedsSharperSource(uid, forPixels: 64))
        _ = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(feed.decodedNeedsSharperSource(uid, forPixels: 64))  // present but materially undersized
        #expect(!feed.decodedNeedsSharperSource(uid, forPixels: 18))  // A value within hysteresis is adequate.
    }

    #if DEBUG
        @Test func decodedCacheRejectsLateLowerResolutionAndReportsTheCurrentSource() {
            let cache = DecodedThumbnailCache(costLimit: 10_000_000)
            let a = Self.uid("dc-upgrade")
            #expect(cache.set(Self.decodedThumb(10, 10), for: a, decodePixelCap: 16))  // 400 bytes
            #expect(cache.set(Self.decodedThumb(20, 20), for: a, decodePixelCap: 320))
            #expect(cache.snapshotForTesting().count == 1)
            #expect(cache.snapshotForTesting().cost == 1600)
            // The false result prevents onDecoded consumers from treating this rejected source as current.
            #expect(!cache.set(Self.decodedThumb(10, 10), for: a, decodePixelCap: 16))
            #expect(cache.snapshotForTesting().cost == 1600)
            #expect(cache.image(for: a)?.pixelWidth == 20)
        }
    #endif

    @Test func decodedRamTierRespondsToMemoryPressureThroughFeed() async throws {
        // End-to-end through the feed: warmDecoded stores into the decoded tier; a critical pressure purge
        // drops it; restoring the budget lets a fresh decode land again.
        let uid = Self.uid("dc-pressure")
        let diskCache = Self.cache("dc-pressure")
        diskCache.storeToDisk(Self.pngData(width: 12, height: 12), for: uid)
        let feed = ThumbnailFeedCore(cache: diskCache, loader: RecordingLoader(), configuration: Self.configuration())

        _ = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(feed.memoryDecoded(for: uid) != nil)

        feed.applyDecodedMemoryPressure(scale: 0.0, purge: true)  // Critical pressure shrinks the budget and purges.
        #expect(feed.memoryDecoded(for: uid) == nil)

        feed.applyDecodedMemoryPressure(scale: 1.0, purge: false)  // Restore the full budget.
        _ = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(feed.memoryDecoded(for: uid) != nil)  // decodes land again
    }

    @Test func memoryOnlyRenderReadPathNeverFallsThroughToDiskOrDecode() async throws {
        // The per-frame render read (`memoryDecoded`) must be a pure RAM lookup: bytes sitting on disk must
        // not be silently read/decrypted/decoded by it - that is warmDecoded's (off-render) job. A nil here
        // despite disk-present bytes is the proof; after an explicit warm the same read serves from RAM.
        let uid = Self.uid("render-pure")
        let diskCache = Self.cache("render-pure")
        diskCache.storeToDisk(Self.pngData(width: 12, height: 12), for: uid)
        let feed = ThumbnailFeedCore(cache: diskCache, loader: RecordingLoader(), configuration: Self.configuration())

        #expect(diskCache.hasUsableDiskData(uid))  // bytes are on disk…
        #expect(feed.memoryDecoded(for: uid) == nil)  // …but the render read does no disk work
        #expect(feed.memoryDecoded(for: uid) == nil)  // stable: repeated reads stay memory-only

        _ = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(feed.memoryDecoded(for: uid) != nil)  // the off-render warm fills the RAM tier
    }

    @Test func backgroundCachedDecodeNeverStartsNetworkWork() async {
        let present = Self.uid("background-cache-hit")
        let missing = Self.uid("background-cache-miss")
        let cache = Self.cache("background-cache")
        cache.storeToDisk(Self.pngData(width: 24, height: 12), for: present)
        let loader = RecordingLoader(payloads: [missing: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration())

        let decoded = await feed.backgroundCachedDecoded(for: present)
        #expect(decoded?.pixelWidth == 16)
        #expect(decoded?.pixelHeight == 8)
        #expect(feed.memoryDecoded(for: present) == nil)
        #expect(await feed.backgroundCachedDecoded(for: missing) == nil)
        #expect(await loader.requestCount() == 0)
    }

    @Test func oldFeedCannotPublishThumbnailAfterAccountSwitch() async {
        let uid = Self.uid("old-feed-after-account-switch")
        let cache = Self.cache("old-feed-after-account-switch")
        cache.storeToDisk(Self.pngData(width: 24, height: 12), for: uid)
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: RecordingLoader(),
            configuration: Self.configuration()
        )

        let beforeSwitch = await feed.backgroundThumbnailDecodeResult(for: uid)
        guard case .decoded = beforeSwitch else {
            Issue.record("the account-A thumbnail must decode before the account switch")
            return
        }

        cache.configure(accountUID: "acct-B", key: feedCacheTestKey)
        cache.storeToDisk(Self.pngData(width: 12, height: 12), for: uid)
        let afterSwitch = await feed.backgroundThumbnailDecodeResult(for: uid)
        guard case .missing = afterSwitch else {
            Issue.record("an account-A feed must not publish account-B disk data")
            return
        }
    }

    @Test func diskHitsDoNotBecomeDownloads() async throws {
        let uids = (0..<3).map { Self.uid("disk-hit-\($0)") }
        let cache = Self.cache("diskhits")
        for uid in uids { cache.storeToDisk(Self.pngData(width: 8, height: 8), for: uid) }
        let loader = RecordingLoader()
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration())

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await feed.prefetchStatus().diskHit >= 3 }

        let status = await feed.prefetchStatus()
        #expect(status.downloadStarted == 0)
        #expect(status.failed == 0)
        #expect(await loader.requestCount() == 0)
    }

    @Test func removedValidatedBlobFallsBackToNetwork() async throws {
        let uid = Self.uid("validated-then-removed")
        let cache = Self.cache("validated-then-removed")
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: uid)
        #expect(cache.hasUsableDiskData(uid))
        try FileManager.default.removeItem(at: cache.diskURL(for: uid))

        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 16, height: 16)])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        let warm = await feed.warmDecoded(
            [ThumbnailRequest(uid: uid)],
            priority: .visibleNow,
            limit: 1
        )
        #expect(warm.queuedNetwork == 1)
        try await Self.waitUntil { await loader.requestCount() == 1 }
        #expect(await loader.fetched(uid))
    }

    @Test func diskHitOnlyCrawlPersistsCheckpointForRelaunch() async throws {
        // When a whole crawl is already on disk, no network batch runs. The checkpoint still must advance to
        // the end, otherwise the next app launch reports the full library as pending previews and counts down
        // through a redundant disk scan.
        let uids = (0..<12).map { Self.uid("disk-checkpoint-\($0)") }
        let cache = Self.cache("disk-checkpoint")
        for uid in uids { cache.storeToDisk(Self.pngData(width: 8, height: 8), for: uid) }

        let firstFeed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(), configuration: Self.configuration())
        await firstFeed.startPrefetch(uids)
        try await Self.waitUntil { await firstFeed.prefetchStatus().currentQueueLength == 0 }
        try await Self.waitUntil { await firstFeed.prefetchStatus().diskCoverageVerified }
        #expect(await firstFeed.prefetchStatus().diskHit >= uids.count)
        await firstFeed.stopPrefetch()

        let relaunchedFeed = ThumbnailFeedCore(
            cache: cache, loader: RecordingLoader(), configuration: Self.configuration())
        await relaunchedFeed.startPrefetch(uids)
        try await Self.waitUntil { await relaunchedFeed.prefetchStatus().diskCoverageVerified }
        let relaunched = await relaunchedFeed.prefetchStatus()
        #expect(relaunched.currentQueueLength == 0)
        #expect(relaunched.diskFileCount == uids.count)
        await relaunchedFeed.stopPrefetch()
    }

    @Test func coverageCheckpointSkipsKnownUIDsButFetchesNewRemoteUIDs() async throws {
        let cached = (0..<8).map { Self.uid("persist-known-\($0)") }
        let newFirst = Self.uid("persist-new-first")
        let newLast = Self.uid("persist-new-last")
        let cache = Self.cache("persist-known")
        let firstStore = Self.checkpointStore(for: cache)
        let firstLoader = RecordingLoader(
            payloads: Dictionary(uniqueKeysWithValues: cached.map { ($0, Self.pngData(width: 8, height: 8)) })
        )
        let firstFeed = ThumbnailFeedCore(
            cache: cache,
            loader: firstLoader,
            configuration: Self.configuration(downloadConcurrencyLimit: 2, batchSize: 2),
            coverageStore: firstStore
        )

        await firstFeed.startPrefetch(cached)
        try await Self.waitUntil { await firstFeed.prefetchStatus().diskCoverageVerified }
        #expect(await firstLoader.requestCount() == cached.count)
        await firstFeed.stopPrefetch()

        let relaunchedStore = Self.checkpointStore(for: cache)
        let relaunchedLoader = RecordingLoader(
            payloads: [
                newFirst: Self.pngData(width: 8, height: 8),
                newLast: Self.pngData(width: 8, height: 8),
            ]
        )
        let relaunchedFeed = ThumbnailFeedCore(
            cache: cache,
            loader: relaunchedLoader,
            configuration: Self.configuration(downloadConcurrencyLimit: 2, batchSize: 2),
            coverageStore: relaunchedStore
        )

        await relaunchedFeed.startPrefetch([newFirst] + cached + [newLast])
        try await Self.waitUntil { await relaunchedFeed.prefetchStatus().diskCoverageVerified }

        #expect(await relaunchedLoader.requestCount() == 2)
        #expect(await relaunchedLoader.fetched(newFirst))
        #expect(await relaunchedLoader.fetched(newLast))
        for uid in cached {
            #expect(await relaunchedLoader.fetched(uid) == false)
        }
        #expect(cache.hasUsableDiskData(newFirst))
        #expect(cache.hasUsableDiskData(newLast))
        await relaunchedFeed.stopPrefetch()
    }

    @Test func cacheClearInvalidatesPersistentCoverageCheckpoint() async throws {
        let uids = (0..<6).map { Self.uid("clear-checkpoint-\($0)") }
        let cache = Self.cache("clear-checkpoint")
        let firstLoader = RecordingLoader(
            payloads: Dictionary(uniqueKeysWithValues: uids.map { ($0, Self.pngData(width: 8, height: 8)) })
        )
        let firstFeed = ThumbnailFeedCore(
            cache: cache,
            loader: firstLoader,
            configuration: Self.configuration(downloadConcurrencyLimit: 2, batchSize: 2),
            coverageStore: Self.checkpointStore(for: cache)
        )

        await firstFeed.startPrefetch(uids)
        try await Self.waitUntil { await firstFeed.prefetchStatus().diskCoverageVerified }
        await firstFeed.stopPrefetch()

        await cache.clear()

        let afterClearLoader = RecordingLoader(
            payloads: Dictionary(uniqueKeysWithValues: uids.map { ($0, Self.pngData(width: 8, height: 8)) })
        )
        let afterClearFeed = ThumbnailFeedCore(
            cache: cache,
            loader: afterClearLoader,
            configuration: Self.configuration(downloadConcurrencyLimit: 2, batchSize: 2),
            coverageStore: Self.checkpointStore(for: cache)
        )

        await afterClearFeed.startPrefetch(uids)
        try await Self.waitUntil { await afterClearFeed.prefetchStatus().downloadCompleted == uids.count }
        #expect(await afterClearLoader.requestCount() == uids.count)
        await afterClearFeed.stopPrefetch()
    }

    @Test func liveCacheClearRestartsCurrentCrawlWithoutStaleCoverage() async throws {
        let uids = (0..<4).map { Self.uid("live-clear-\($0)") }
        let cache = Self.cache("live-clear")
        let loader = RecordingLoader(
            payloads: Dictionary(uniqueKeysWithValues: uids.map { ($0, Self.pngData(width: 8, height: 8)) })
        )
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 2),
            coverageStore: Self.checkpointStore(for: cache)
        )

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await feed.prefetchStatus().diskCoverageVerified }
        #expect(await loader.requestCount() == uids.count)

        await feed.clearCacheAndRestartPrefetch()
        try await Self.waitUntil { await loader.requestCount() == uids.count * 2 }
        try await Self.waitUntil { await feed.prefetchStatus().diskCoverageVerified }

        for uid in uids { #expect(cache.hasUsableDiskData(uid)) }
        #expect(await feed.prefetchStatus().diskFileCount == uids.count)
        await feed.stopPrefetch()
    }

    @Test(arguments: [true, false], [true, false])
    func liveCacheClearUsesBoundInventoryWhenPrimaryInventoryIsEmpty(
        includedInLibrary: Bool,
        prefetchEnabled: Bool
    ) async throws {
        let uid = Self.uid("bound-clear")
        let cache = Self.cache("bound-clear")
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration())
        let graph = LibrarySourceGraph()
        let change = Self.visibleScope(in: graph, uids: [uid], includedInLibrary: includedInLibrary)
        #expect(await feed.bindDerivedDataEpoch(graph.runtimeEpoch))
        _ = await feed.reconcile(
            selected: change.selectedScope,
            analysis: change.analysisScope,
            retention: change.thumbnailRetentionScope
        )
        try await feed.waitForPrefetchToFinish()
        #expect(await loader.requestCount() == 1)
        #expect(cache.hasUsableDiskData(uid))

        await feed.setPrefetchEnabled(prefetchEnabled)
        // The host's primary timeline can be empty; the admitted source scopes still own the crawl.
        await feed.clearCacheAndRestartPrefetch()
        try await feed.waitForPrefetchToFinish()

        #expect(await loader.requestCount() == (prefetchEnabled ? 2 : 1))
        #expect(cache.hasUsableDiskData(uid) == prefetchEnabled)
        await feed.stopPrefetchAndWait()
    }

    @Test func implausibleCoverageCheckpointFallsBackToDiskVerification() async throws {
        let present = Self.uid("implausible-present")
        let missing = Self.uid("implausible-missing")
        let cache = Self.cache("implausible-checkpoint")
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: present)
        let store = Self.checkpointStore(for: cache)
        store.recordPresent([present, missing], for: "thumbnail-coverage-v1")
        let loader = RecordingLoader(payloads: [missing: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 2),
            coverageStore: store
        )

        await feed.startPrefetch([present, missing])
        try await Self.waitUntil { await feed.prefetchStatus().diskCoverageVerified }

        #expect(await loader.requestCount() == 1)
        #expect(await loader.fetched(missing))
        #expect(await loader.fetched(present) == false)
        await feed.stopPrefetch()
    }

    @Test func equalCountCheckpointReplacementStillRefetchesRemovedUID() async throws {
        let present = Self.uid("equal-count-present")
        let removed = Self.uid("equal-count-removed")
        let replacement = Self.uid("equal-count-replacement")
        let cache = Self.cache("equal-count-checkpoint")
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: present)
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: removed)
        let store = Self.checkpointStore(for: cache)
        store.recordPresent([present, removed], for: "thumbnail-coverage-v1")

        // Keep the directory file count unchanged while removing one checkpoint member.
        try FileManager.default.removeItem(at: cache.diskURL(for: removed))
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: replacement)
        #expect(cache.diskFileCount() == 2)

        let loader = RecordingLoader(payloads: [removed: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 2),
            coverageStore: store
        )

        await feed.startPrefetch([present, removed])
        try await Self.waitUntil { await feed.prefetchStatus().diskCoverageVerified }

        #expect(await loader.requestCount() == 1)
        #expect(await loader.fetched(removed))
        #expect(await loader.fetched(present) == false)
        await feed.stopPrefetch()
    }

    @Test func equalCountCheckpointDoesNotTrustCorruptedValidatedBlob() async throws {
        let present = Self.uid("equal-count-corrupt-present")
        let corrupted = Self.uid("equal-count-corrupt-member")
        let cache = Self.cache("equal-count-corrupt-checkpoint")
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: present)
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: corrupted)
        let store = Self.checkpointStore(for: cache)
        store.recordPresent([present, corrupted], for: "thumbnail-coverage-v1")

        // `storeToDisk` memoizes both blobs as authenticated. Corrupt one afterward while retaining
        // the same filename and directory count; checkpoint bootstrap must authenticate it again.
        try Data(repeating: 0xA5, count: 64).write(to: cache.diskURL(for: corrupted), options: .atomic)
        #expect(cache.diskFileCount() == 2)

        let loader = RecordingLoader(payloads: [corrupted: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 2),
            coverageStore: store
        )

        await feed.startPrefetch([present, corrupted])
        try await Self.waitUntil { await feed.prefetchStatus().diskCoverageVerified }

        #expect(await loader.requestCount() == 1)
        #expect(await loader.fetched(corrupted))
        #expect(await loader.fetched(present) == false)
        await feed.stopPrefetch()
    }

    @Test func restartedCrawlDoesNotDecryptBlobsThatThisFeedAlreadyAuthenticated() async throws {
        let first = Self.uid("restart-proven-first")
        let second = Self.uid("restart-proven-second")
        let cache = Self.cache("restart-proven")
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: first)
        cache.storeToDisk(Self.pngData(width: 8, height: 8), for: second)
        let loader = RecordingLoader(payloads: [second: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 2)
        )
        await feed.startPrefetch([first, second])
        try await Self.waitUntil { await feed.prefetchStatus().diskCoverageVerified }

        // A source change (for example after an upload) restarts the crawl. The first crawl authenticated both
        // blobs, so the restart only looks them up. A blob changed in place shows whether the restart read it.
        try Data(repeating: 0xA5, count: 64).write(to: cache.diskURL(for: second), options: .atomic)
        await feed.startPrefetch([first, second])
        try await Self.waitUntil { await feed.prefetchStatus().diskCoverageVerified }

        #expect(await loader.requestCount() == 0)
        await feed.stopPrefetch()
    }

    @Test func destructiveClearRejectsLateNonCooperativeThumbnailWriter() async throws {
        let uid = Self.uid("late-thumbnail-after-clear")
        let cache = Self.cache("late-thumbnail-after-clear")
        let loader = ControlledLateLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1, downloadTimeoutSeconds: 0.1)
        )

        await feed.startPrefetch([uid])
        try await Self.waitUntil { await feed.prefetchStatus().failedTimeout == 1 }
        await feed.stopPrefetch()
        await cache.clear()
        await loader.release()
        try await Self.waitUntil { await loader.finishedBatches() >= 1 }
        try await Task.sleep(for: .milliseconds(50))

        #expect(cache.has(uid) == false)
    }

    @Test func ownerTeardownJoinsCancellationIgnoringPrefetchWorker() async throws {
        let uid = Self.uid("owner-teardown-join")
        let loader = ControlledLateLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("owner-teardown-join"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )
        let returned = Counter()

        await feed.startPrefetch([uid])
        try await Self.waitUntil { await loader.requestCount() == 1 }
        let teardown = Task {
            await feed.stopPrefetchAndWait()
            returned.increment()
        }
        await Task.yield()

        #expect(returned.value() == 0, "owner teardown must join a cancellation-ignoring loader")
        await loader.release()
        await teardown.value
        #expect(returned.value() == 1)
        #expect(await loader.finishedBatches() == 1)
    }

    @Test func ownerTeardownJoinsCancellationIgnoringDirectDecodeFlight() async throws {
        let uid = Self.uid("owner-teardown-direct-decode")
        let loader = ControlledLateLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("owner-teardown-direct-decode"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )
        let returned = Counter()
        let request = Task { await feed.decoded(for: uid) }

        try await Self.waitUntil { await loader.requestCount() == 1 }
        let teardown = Task {
            await feed.stopPrefetchAndWait()
            returned.increment()
        }
        await Task.yield()

        #expect(returned.value() == 0, "teardown must join a coalesced direct loader owned by the feed")
        await loader.release()
        _ = await request.value
        await teardown.value
        #expect(returned.value() == 1)
        #expect(await loader.finishedBatches() == 1)
    }

    @Test func ownerTeardownJoinsWorkerRetiredByPrefetchRestart() async throws {
        let firstUID = Self.uid("owner-teardown-restarted-first")
        let secondUID = Self.uid("owner-teardown-restarted-second")
        let payload = Self.pngData(width: 8, height: 8)
        let loader = PerUIDControlledLateLoader(payloads: [firstUID: payload, secondUID: payload])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("owner-teardown-restarted"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )
        let returned = Counter()

        await feed.startPrefetch([firstUID])
        try await Self.waitUntil { await loader.requestCount() == 1 }
        await loader.release(secondUID)
        await feed.startPrefetch([secondUID])

        let teardown = Task {
            await feed.stopPrefetchAndWait()
            returned.increment()
        }
        await Task.yield()
        #expect(returned.value() == 0, "teardown must retain workers replaced by a later prefetch")

        await loader.release(firstUID)
        await teardown.value
        #expect(returned.value() == 1)
        #expect(await loader.finishedBatches() == 1)
        #expect(
            await loader.requestCount() == 1,
            "a replacement loader must not bypass the cancellation-ignoring owner's concurrency slot")
    }

    @Test func accountChangeRejectsLateThumbnailOwner() async throws {
        let uid = Self.uid("late-thumbnail-after-account-change")
        let cache = Self.cache("late-thumbnail-after-account-change")
        let loader = ControlledLateLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.startPrefetch([uid])
        try await Self.waitUntil { await loader.requestCount() == 1 }
        cache.configure(accountUID: "acct-B", key: feedCacheTestKey)
        await loader.release()
        try await Self.waitUntil { await loader.finishedBatches() == 1 }
        try await Task.sleep(for: .milliseconds(50))

        #expect(cache.has(uid) == false)
        #expect(cache.diskData(for: uid) == nil)
        #expect(feed.memoryDecoded(for: uid) == nil)
        await feed.stopPrefetch()
    }

    #if DEBUG
        @Test func staleDiskProbeCannotPublishAfterAccountSwitch() async throws {
            let uid = Self.uid("stale-disk-probe-after-account-switch")
            let cache = Self.cache("stale-disk-probe-after-account-switch")
            let store = RecordingCoverageStore()
            let feed = ThumbnailFeedCore(
                cache: cache,
                loader: RecordingLoader(),
                configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1),
                coverageStore: store
            )
            let probeGate = BlockingDiskProbeHook()
            feed.setDiskProbeHookForTesting { probeGate.wait() }

            await feed.startPrefetch([uid])
            try await Self.waitUntil { probeGate.hasEntered }

            cache.configure(accountUID: "acct-B", key: feedCacheTestKey)
            cache.storeToDisk(Self.pngData(width: 8, height: 8), for: uid)
            probeGate.release.signal()
            try await Self.waitUntil { probeGate.hasExited }
            await feed.stopPrefetch()

            #expect(store.snapshot.isEmpty, "an old feed must not checkpoint a post-switch disk probe")
        }

        @Test func priorityRequestCanRetryAfterClearInterruptsItsDiskProbe() async throws {
            let uid = Self.uid("priority-probe-clear")
            let cache = Self.cache("priority-probe-clear")
            let sessionLease = cache.captureSessionLease()
            let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
            let feed = ThumbnailFeedCore(
                cache: cache,
                loader: loader,
                configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
            )
            let probeGate = BlockingDiskProbeHook()
            let clearGate = BlockingDiskProbeHook()
            defer {
                probeGate.release.signal()
                clearGate.release.signal()
            }
            feed.setDiskProbeHookForTesting { probeGate.wait() }
            await cache.setClearHookForTesting { clearGate.wait() }

            #expect(await feed.requestPriority(uid))
            try #require(await Self.waitForLeaseTest { probeGate.hasEntered })
            let clearTask = Task.detached { await cache.clear() }
            try #require(await Self.waitForLeaseTest { clearGate.hasEntered })
            #expect(!cache.isCurrentSessionLease(sessionLease))
            clearGate.release.signal()
            await clearTask.value
            probeGate.release.signal()
            try #require(await Self.waitForLeaseTest { await !feed.downloadCountersForTesting().workersRunning })
            #expect(await loader.requestCount() == 0)
            #expect(cache.isCurrentSessionLease(sessionLease))
            feed.setDiskProbeHookForTesting(nil)
            await cache.setClearHookForTesting(nil)

            #expect(await feed.requestPriority(uid))
            let delivered = await Self.waitForLeaseTest { cache.has(uid) }
            #expect(delivered, "a priority reservation must not hide a retry after its disk probe was invalidated")
            #expect(await loader.requestCount() == 1)
            await feed.stopPrefetchAndWait()
        }

        @Test func priorityRequestCanRetryAfterWorkerLosesLeaseWhileWaitingForDownloadSlot() async throws {
            let first = Self.uid("priority-slot-first")
            let waiting = Self.uid("priority-slot-waiting")
            let cache = Self.cache("priority-slot-clear")
            let sessionLease = cache.captureSessionLease()
            let loader = ControlledLateLoader(payloads: [waiting: Self.pngData(width: 8, height: 8)])
            let feed = ThumbnailFeedCore(
                cache: cache,
                loader: loader,
                configuration: Self.configuration(
                    downloadConcurrencyLimit: 2,
                    batchSize: 1,
                    downloadTimeoutSeconds: 30
                )
            )
            let slotWaits = Counter()
            let clearGate = BlockingDiskProbeHook()
            defer {
                clearGate.release.signal()
                Task { await loader.release() }
            }
            await feed.setDownloadSlotWaitHookForTesting { slotWaits.increment() }
            await cache.setClearHookForTesting { clearGate.wait() }

            #expect(await feed.requestPriority(first))
            try #require(await Self.waitForLeaseTest { await loader.isWaiting() })
            #expect(await feed.requestPriority(waiting))
            try #require(await Self.waitForLeaseTest { slotWaits.value() > 0 })
            let clearTask = Task.detached { await cache.clear() }
            try #require(await Self.waitForLeaseTest { clearGate.hasEntered })
            #expect(!cache.isCurrentSessionLease(sessionLease))
            await loader.release()
            try #require(await Self.waitForLeaseTest { await !feed.downloadCountersForTesting().workersRunning })
            #expect(await loader.requestCount() == 1)
            clearGate.release.signal()
            await clearTask.value
            #expect(cache.isCurrentSessionLease(sessionLease))
            await cache.setClearHookForTesting(nil)

            #expect(await feed.requestPriority(waiting))
            let delivered = await Self.waitForLeaseTest { cache.has(waiting) }
            #expect(delivered, "a worker that loses its lease must release its priority reservation")
            #expect(await loader.requestedOrder() == [first, waiting])
            await feed.stopPrefetchAndWait()
            #expect(await feed.downloadCountersForTesting().downloadInFlight == 0)
        }

        @Test func priorityReservationInNewGenerationSurvivesOldProbeCompletion() async throws {
            let uid = Self.uid("priority-restarted-probe")
            let loader = ControlledLateLoader(payloads: [:])
            let feed = ThumbnailFeedCore(
                cache: Self.cache("priority-restarted-probe"),
                loader: loader,
                configuration: Self.configuration(
                    downloadConcurrencyLimit: 1,
                    batchSize: 1,
                    downloadTimeoutSeconds: 30
                )
            )
            let probeGate = BlockingDiskProbeHook()
            defer {
                probeGate.release.signal()
                Task { await loader.release() }
            }
            feed.setDiskProbeHookForTesting { probeGate.wait() }
            #expect(await feed.requestPriority(uid))
            try #require(await Self.waitForLeaseTest { probeGate.hasEntered })

            feed.setDiskProbeHookForTesting(nil)
            await feed.startPrefetch([])
            try #require(await Self.waitForLeaseTest { await loader.isWaiting() })
            probeGate.release.signal()
            await feed.waitForRetiredWorkersForTesting()

            #expect(await feed.requestPriority(uid))
            #expect(
                await feed.prefetchStatus().currentQueueLength == 0,
                "old probe cleanup must preserve the replacement generation's active reservation")
            #expect(await loader.requestCount() == 1)
            await loader.release()
            await feed.stopPrefetchAndWait()
        }

        /// `crawlRuns` selects the `takeBatch` branch: without a crawl the batch passes through
        /// `finishDiskProbeBatch`, with a crawl and no visible demand it takes the regular path.
        @Test(arguments: [false, true])
        func priorityReservationOfADownloadingBatchStaysUntilTheLoadEnds(crawlRuns: Bool) async throws {
            let uid = Self.uid("priority-handed-over-\(crawlRuns)")
            let cache = Self.cache("priority-handed-over-\(crawlRuns)")
            let loader = ControlledLateLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
            let feed = ThumbnailFeedCore(
                cache: cache,
                loader: loader,
                configuration: Self.configuration(
                    downloadConcurrencyLimit: 1,
                    batchSize: 1,
                    downloadTimeoutSeconds: 30
                )
            )
            defer { Task { await loader.release() } }
            // An idle-crawl request records no visible demand, which would send the batch down the other branch.
            let requestedPriority: ThumbnailPriority = crawlRuns ? .idleLibraryCrawl : .visibleNow
            if crawlRuns { await feed.startPrefetch([]) }

            #expect(await feed.requestPriority(uid, priority: requestedPriority))
            try #require(await Self.waitForLeaseTest { await loader.isWaiting() })

            #expect(await feed.requestPriority(uid, priority: requestedPriority))
            #expect(
                await feed.prefetchStatus().currentQueueLength == 0,
                "a batch handed to the download keeps its reservation, so a repeated request queues nothing")
            await loader.release()
            #expect(await Self.waitForLeaseTest { cache.has(uid) })
            #expect(await loader.requestCount() == 1)
            await feed.stopPrefetchAndWait()
        }

        private static func waitForLeaseTest(_ condition: @Sendable () async -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                if await condition() { return true }
                await Task.yield()
            }
            return await condition()
        }

        @Test func workerThatLosesItsLeaseWhileWaitingForADownloadSlotLeavesNoDownloadCounters() async throws {
            let uids = ["lease-lost-a", "lease-lost-b"].map { Self.uid($0) }
            let cache = Self.cache("lease-lost-while-waiting-for-a-slot")
            let loader = ControlledLateLoader(payloads: [:])
            let feed = ThumbnailFeedCore(
                cache: cache,
                loader: loader,
                configuration: Self.configuration(
                    downloadConcurrencyLimit: 2,
                    batchSize: 1,
                    downloadTimeoutSeconds: 30
                )
            )

            await feed.startPrefetch(uids)
            // The configuration allows one download at a time. The first worker holds that slot inside the
            // loader; the second one has taken its batch and polls for a free slot.
            try await Self.waitUntil {
                let queueLength = await feed.prefetchStatus().currentQueueLength
                return await loader.requestCount() == 1 && queueLength == 0
            }
            try await Task.sleep(for: .milliseconds(300))
            let waiting = await feed.downloadCountersForTesting()
            #expect(waiting.activeDownloaders == 1)
            #expect(waiting.downloadInFlight == 1)

            // The account changes while the second worker waits. The first download then frees the slot.
            cache.configure(accountUID: "acct-B", key: feedCacheTestKey)
            await loader.release()
            try await Self.waitUntil { await !feed.downloadCountersForTesting().workersRunning }

            let stopped = await feed.downloadCountersForTesting()
            #expect(!stopped.workersRunning)
            #expect(stopped.activeDownloaders == 0, "a worker that stops on a lost lease must not keep a download slot")
            #expect(stopped.downloadInFlight == 0, "a worker that stops on a lost lease must not keep in-flight items")
            let status = await feed.prefetchStatus()
            #expect(status.downloadsInFlight == 0)
            #expect(status.activeJobs == 0)
            await feed.stopPrefetch()
        }
    #endif

    @Test func prefetchStatusReportsIncrementalDiskCoverage() async throws {
        let cached = (0..<2).map { Self.uid("coverage-cached-\($0)") }
        let missing = Self.uid("coverage-missing")
        let cache = Self.cache("coverage")
        for uid in cached { cache.storeToDisk(Self.pngData(width: 8, height: 8), for: uid) }
        let loader = RecordingLoader(itemErrors: [missing: "no thumbnail for node"])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.startPrefetch(cached + [missing])
        try await Self.waitUntil {
            let status = await feed.prefetchStatus()
            return status.diskHit >= cached.count && status.failedItemError == 1
        }

        let status = await feed.prefetchStatus()
        #expect(status.diskThumbnailTotal == 3)
        #expect(status.diskFileCount == 2)
        #expect(status.diskThumbnailCoverageFraction == 2.0 / 3.0)
        #expect(await loader.requestCount() == 1)
    }

    @Test func timeoutDoesNotDoubleCountCompletionOrFailure() async throws {
        let uid = Self.uid("timeout")
        let cache = Self.cache("timeout")
        let loader = ControlledLateLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1, downloadTimeoutSeconds: 0.1)
        )

        await feed.startPrefetch([uid])
        try await Self.waitUntil { await feed.prefetchStatus().failedTimeout == 1 }

        let atTimeout = await feed.prefetchStatus()
        #expect(atTimeout.downloadStarted == 1)
        #expect(atTimeout.downloadCompleted == 0)
        #expect(atTimeout.failed == 1)

        // The uncancellable loader finishes only after the test explicitly releases it. This avoids racing a
        // real-time loader delay against the timeout task when the complete package suite is under heavy load.
        await loader.release()
        // Its bytes land on disk, but the batch was
        // already accounted: failed stays 1, completed stays 0 (never both for one item).
        try await Self.waitUntil { await loader.finishedBatches() >= 1 }
        try await Self.waitUntil { cache.has(uid) }
        let afterLateDelivery = await feed.prefetchStatus()
        #expect(afterLateDelivery.downloadCompleted == 0)
        #expect(afterLateDelivery.failed == 1)
        #expect(afterLateDelivery.downloadStarted == 1)

        // The late-delivered blob is now a disk hit: a new visible request must not re-download.
        await feed.requestPriority(uid, priority: .visibleNow)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await loader.requestCount() == 1)
    }

    @Test func timedOutSDKLoaderKeepsItsConcurrencySlotUntilItReturns() async throws {
        let uids = (0..<6).map { Self.uid("timeout-bound-\($0)") }
        let loader = NonCooperativeLoader(delay: .seconds(1))
        let feed = ThumbnailFeedCore(
            cache: Self.cache("timeout-bound"),
            loader: loader,
            configuration: Self.configuration(
                downloadConcurrencyLimit: 1,
                batchSize: 1,
                crawlBackoffSeconds: 0,
                downloadTimeoutSeconds: 0.1
            )
        )

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await feed.prefetchStatus().failedTimeout == 1 }
        try await Task.sleep(for: .milliseconds(350))

        #expect(await loader.requestCount() == 1)
        #expect(await feed.prefetchStatus().downloadsInFlight == 1)
        await feed.stopPrefetch()
    }

    @Test func timeoutCancelsCooperativeLoaderAndCrawlContinues() async throws {
        let uids = (0..<3).map { Self.uid("timeout-cancel-\($0)") }
        let loader = CancellationAwareLoader(delay: .seconds(10))
        let feed = ThumbnailFeedCore(
            cache: Self.cache("timeout-cancel"),
            loader: loader,
            configuration: Self.configuration(
                downloadConcurrencyLimit: 1,
                batchSize: 1,
                crawlBackoffSeconds: 0,
                downloadTimeoutSeconds: 0.1
            )
        )

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await loader.cancellations() >= 2 }

        #expect(await loader.requestCount() >= 2)
        #expect(await feed.prefetchStatus().failedTimeout >= 2)
        await feed.stopPrefetch()
    }

    @Test func interactionSignalDoesNotPauseThumbnailPrefetch() async throws {
        let uids = (0..<2).map { Self.uid("interact-\($0)") }
        let loader = RecordingLoader(
            payloads: Dictionary(uniqueKeysWithValues: uids.map { ($0, Self.pngData(width: 8, height: 8)) }))
        let feed = ThumbnailFeedCore(cache: Self.cache("interact"), loader: loader, configuration: Self.configuration())

        let grid = ThumbnailInteractionOwner()
        feed.setUserInteractionActive(true, owner: grid)
        await feed.startPrefetch(uids)
        try await Self.waitUntil { await feed.prefetchStatus().downloadCompleted == 2 }
        let status = await feed.prefetchStatus()
        #expect(!status.paused)
        #expect(status.pausedReason == "none")
        #expect(await loader.requestCount() == 2)
        feed.setUserInteractionActive(false, owner: grid)
    }

    @Test func refusedItemsAreQuarantinedUntilNextCrawlStart() async throws {
        let uid = Self.uid("refused")
        let loader = RecordingLoader(itemErrors: [uid: "no thumbnail for node"])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("refused"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.startPrefetch([uid])
        try await Self.waitUntil { await feed.prefetchStatus().failedItemError == 1 }
        #expect(await loader.requestCount() == 1)

        // Same crawl: the refused uid is quarantined - a new priority request must not re-download.
        await feed.requestPriority(uid, priority: .visibleNow)
        try await Self.waitUntil { await feed.prefetchStatus().skippedUnfetchable >= 1 }
        #expect(await loader.requestCount() == 1)

        // A fresh crawl start clears the quarantine and retries exactly once.
        await feed.startPrefetch([uid])
        await feed.requestPriority(uid, priority: .visibleNow)
        try await Self.waitUntil { await loader.requestCount() == 2 }
        #expect(await loader.requestCount() == 2)
    }

    @Test func aWithheldThumbnailIsNotQuarantinedAndTheCrawlLoadsItAgain() async throws {
        // A library large enough that the end-of-crawl coverage pass settles with one photo missing; only the
        // requeue can fetch that photo again.
        let uids = (0..<400).map { Self.uid("withheld-\($0)") }
        let withheld = uids[7]
        let png = Self.pngData(width: 8, height: 8)
        let loader = RecordingLoader(
            payloads: Dictionary(uniqueKeysWithValues: uids.map { ($0, png) }), withheldOnce: [withheld])
        let cache = Self.cache("withheld")
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 2, batchSize: 50)
        )

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await loader.requestOrder().filter { $0 == withheld }.count == 2 }

        #expect(await loader.requestOrder().filter { $0 == withheld }.count == 2)
        let status = await feed.prefetchStatus()
        #expect(status.failedWithheld == 1)
        #expect(status.unfetchableCount == 0, "an authorization change during the download is not the photo's fault")
        #expect(status.failedUnreported == 0, "and no transport problem either")
        try await Self.waitUntil { cache.diskData(for: withheld) != nil }
        #expect(cache.diskData(for: withheld) != nil, "the crawl stored it without any visible request")
    }

    @Test func turningPrefetchOffDropsPendingWithheldRetries() async throws {
        let uid = Self.uid("withheld-then-off")
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)], withheldOnce: [uid])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("withheld-then-off"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1, crawlBackoffSeconds: 30)
        )

        await feed.startPrefetch([uid])
        try await Self.waitUntil { await feed.prefetchStatus().failedWithheld == 1 }
        // The retry waits behind the crawl backoff and shows in the queue.
        #expect(await feed.prefetchStatus().currentQueueLength == 1)

        await feed.setPrefetchEnabled(false)

        // Nothing would take the retry now, and a pending retry would keep the workers polling.
        #expect(await feed.prefetchStatus().currentQueueLength == 0)
        #expect(await loader.requestCount() == 1)
    }

    @Test func visiblePathDoesNotRefetchBackendRefusedItems() async throws {
        let uid = Self.uid("visible-refused")
        let loader = RecordingLoader(itemErrors: [uid: "Node has no thumbnails"])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("visible-refused"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        // First visible request hits the loader and learns the refusal…
        #expect(await feed.decoded(for: uid) == nil)
        #expect(await loader.requestCount() == 1)
        // …every further visibility is short-circuited for this crawl.
        #expect(await feed.decoded(for: uid) == nil)
        #expect(await feed.decoded(for: uid) == nil)
        #expect(await loader.requestCount() == 1)

        // A fresh crawl start retries once (the node may have gained a thumbnail since).
        await feed.startPrefetch([])
        #expect(await feed.decoded(for: uid) == nil)
        #expect(await loader.requestCount() == 2)
    }

    @Test func refusalOfAJustJoinedPhotoLapsesSoItsTileFills() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let old = Self.uid("lapse-old")
        let joined = Self.uid("lapse-joined")
        let loader = RecordingLoader(
            payloads: [joined: Self.pngData(width: 8, height: 8)],
            refusedOnce: [joined: "no thumbnail for node"]
        )
        let feed = await Self.feedWithJoinedPhotos(
            "lapse", existing: [old], joined: [joined], loader: loader, clock: clock)

        #expect(await feed.decoded(for: joined) == nil)
        #expect(feed.isKnownUnfetchable(joined))
        #expect(await feed.decoded(for: joined) == nil, "the refusal holds until it lapses")
        #expect(await loader.requestCount() == 1)

        clock.advance(ThumbnailFeedCore.recentJoinRefusalLapse)
        #expect(!feed.isKnownUnfetchable(joined))
        #expect(await feed.decoded(for: joined) != nil, "the tile fills without a new snapshot")
        #expect(await loader.requestCount() == 2)
        await feed.stopPrefetchAndWait()
    }

    /// A feed without a source graph reports its membership through `startPrefetch`; a photo that joins there also
    /// gets its refusal lapsed.
    @Test func refusalOfAPhotoThatJoinedThroughStartPrefetchLapses() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let old = Self.uid("prefetch-old")
        let joined = Self.uid("prefetch-joined")
        let loader = RecordingLoader(
            payloads: [old: Self.pngData(width: 8, height: 8), joined: Self.pngData(width: 8, height: 8)],
            refusedOnce: [joined: "no thumbnail for node"]
        )
        let feed = ThumbnailFeedCore(
            cache: Self.cache("prefetch-join"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1),
            clock: { clock.read() }
        )
        await feed.setPrefetchEnabled(false)
        await feed.startPrefetch([old])
        await feed.startPrefetch([old, joined])

        #expect(await feed.decoded(for: joined) == nil)
        #expect(feed.isKnownUnfetchable(joined))
        clock.advance(ThumbnailFeedCore.recentJoinRefusalLapse)
        #expect(!feed.isKnownUnfetchable(joined), "a photo that joined moments ago is asked again")
        await feed.stopPrefetchAndWait()
    }

    @Test func refusalOfAnOlderPhotoHoldsUntilTheNextCrawl() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let old = Self.uid("hold-old")
        let aged = Self.uid("hold-aged")
        let loader = RecordingLoader(itemErrors: [old: "no thumbnail for node", aged: "no thumbnail for node"])
        let feed = await Self.feedWithJoinedPhotos(
            "hold", existing: [old], joined: [aged], loader: loader, clock: clock)

        #expect(await feed.decoded(for: old) == nil)
        // The first refusal of the joined photo comes when its join window has closed.
        clock.advance(ThumbnailFeedCore.recentJoinRefusalWindow)
        #expect(await feed.decoded(for: aged) == nil)
        clock.advance(ThumbnailFeedCore.recentJoinRefusalLapse * 3)

        #expect(feed.isKnownUnfetchable(old))
        #expect(feed.isKnownUnfetchable(aged))
        #expect(await feed.decoded(for: old) == nil)
        #expect(await feed.decoded(for: aged) == nil)
        #expect(await loader.requestCount() == 2)
        await feed.stopPrefetchAndWait()
    }

    @Test func refusalsOfAJustJoinedPhotoLapseABoundedNumberOfTimes() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let old = Self.uid("bounded-old")
        let joined = Self.uid("bounded-joined")
        let loader = RecordingLoader(itemErrors: [joined: "no thumbnail for node"])
        let feed = await Self.feedWithJoinedPhotos(
            "bounded", existing: [old], joined: [joined], loader: loader, clock: clock)
        let rounds = ThumbnailFeedCore.maxRecentJoinRefusalLapses + 3
        // Every round stays inside the join window, so only the lapse bound stops the retries.
        #expect(Double(rounds) * ThumbnailFeedCore.recentJoinRefusalLapse < ThumbnailFeedCore.recentJoinRefusalWindow)

        for _ in 0..<rounds {
            _ = await feed.decoded(for: joined)
            // A second visible request before the lapse never reaches the loader.
            _ = await feed.decoded(for: joined)
            clock.advance(ThumbnailFeedCore.recentJoinRefusalLapse)
        }

        #expect(await loader.requestCount() == 1 + ThumbnailFeedCore.maxRecentJoinRefusalLapses)
        #expect(feed.isKnownUnfetchable(joined))
        await feed.stopPrefetchAndWait()
    }

    /// A feed whose source first lists `existing`, then `existing + joined` in a later revision. Prefetch is off,
    /// so only visible requests reach the loader.
    private static func feedWithJoinedPhotos(
        _ name: String,
        existing: [PhotoUID],
        joined: [PhotoUID],
        loader: RecordingLoader,
        clock: MutableClock
    ) async -> ThumbnailFeedCore {
        let feed = ThumbnailFeedCore(
            cache: Self.cache(name),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1),
            clock: { clock.read() }
        )
        await feed.setPrefetchEnabled(false)
        let source = LibrarySource(id: SourceID("\(name)-source"), capabilities: .readThumbnail)
        let graph = LibrarySourceGraph()
        _ = graph.commitSourceSet([source], using: graph.beginSourceSetRefresh())
        #expect(await feed.bindDerivedDataEpoch(graph.runtimeEpoch))
        for uids in [existing, existing + joined] {
            let change = graph.commit(
                Self.sourceItems(uids), validationToken: nil, using: graph.beginRefresh(source.id)!)!
            _ = await feed.reconcile(
                selected: change.selectedScope, analysis: change.analysisScope,
                retention: change.thumbnailRetentionScope)
        }
        return feed
    }

    @Test func diagnosticsExplainEveryFailure() async throws {
        let refused = Self.uid("diag-refused")
        let loader = RecordingLoader(itemErrors: [refused: "decrypt failed"])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("diag"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.startPrefetch([refused])
        try await Self.waitUntil { await feed.prefetchStatus().failed == 1 }

        let status = await feed.prefetchStatus()
        // failed=N must decompose into the classified buckets…
        #expect(
            status.failed == status.failedTimeout + status.failedBatchError + status.failedItemError
                + status.failedUnreported + status.failedWithheld)
        #expect(status.failedItemError == 1)
        // …and the human-readable reason must be surfaced.
        #expect(status.lastErrors.joined().contains("decrypt failed"))
    }

    private static func configuration(
        targetPixels: CGFloat = 16,
        downloadConcurrencyLimit: Int = 2,
        initialDownloadConcurrency: Int = 1,
        batchSize: Int = 2,
        maxConcurrentDecodes: Int = 1,
        visibleQuietWindow: TimeInterval = 0.25,
        crawlBackoffSeconds: TimeInterval = 0.25,
        downloadTimeoutSeconds: Double = 1
    ) -> ThumbnailFeedCoreConfiguration {
        ThumbnailFeedCoreConfiguration(
            targetPixels: targetPixels,
            downloadConcurrencyLimit: downloadConcurrencyLimit,
            initialDownloadConcurrency: initialDownloadConcurrency,
            minimumDownloadConcurrency: 1,
            batchSize: batchSize,
            decodedMemoryBudgetBytes: 16 * 1024 * 1024,
            maxConcurrentDecodes: maxConcurrentDecodes,
            priorityQueueLimit: 16,
            sequentialScanLimit: 16,
            visibleQuietWindow: visibleQuietWindow,
            crawlBackoffSeconds: crawlBackoffSeconds,
            downloadTimeoutSeconds: downloadTimeoutSeconds
        )
    }

    private static func cache(_ prefix: String, runtimeState: LibraryRuntimeState = .shared) -> ThumbnailCache {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncryptedMemoriesKit-feed-core-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = ThumbnailCache(
            namespace: "feed-core-\(prefix)-\(UUID().uuidString)",
            rootDirectory: root,
            runtimeState: runtimeState
        )
        cache.configure(accountUID: "acct-A", key: feedCacheTestKey)
        return cache
    }

    private static func checkpointStore(for cache: ThumbnailCache) -> FileThumbnailCoverageCheckpointStore {
        FileThumbnailCoverageCheckpointStore(
            directory: cache.coverageCheckpointDirectory(),
            scope: cache.coverageCheckpointScope()
        )
    }

    private static func uid(_ id: String) -> PhotoUID {
        PhotoUID(volumeID: "vol", nodeID: "\(id)-\(UUID().uuidString)")
    }

    private static func sourceItems(_ uids: [PhotoUID]) -> [LibrarySourceItem] {
        uids.enumerated().map { offset, uid in
            .complete(
                PhotoItem(
                    uid: uid,
                    captureTime: Date(timeIntervalSince1970: TimeInterval(offset)),
                    mediaType: "image/jpeg"
                )
            )
        }
    }

    private static func pngData(width: Int, height: Int) -> Data {
        makePNGData(width: width, height: height)
    }

    /// A decoded thumbnail with a known pixel size has deterministic `decodedCostBytes` (width*height*4) for
    /// cost/eviction assertions.
    private static func decodedThumb(_ width: Int, _ height: Int) -> DecodedThumbnail {
        DecodedThumbnail(image: makeCGImage(width: width, height: height))
    }

    /// Waits up to three seconds and records an issue when the condition never holds.
    private static func waitUntil(
        _ condition: @Sendable () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<60 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        if await condition() { return }
        Issue.record("the condition did not hold within 3 s", sourceLocation: sourceLocation)
    }

    /// Joins `task` within 20 s; a task that does not end records an issue and is cancelled.
    private static func join(
        _ task: Task<Void, Never>, _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let ended = OneShotGate()
        Task {
            await task.value
            await ended.open()
        }
        if !(await ended.wait(limit: .seconds(20), sourceLocation: sourceLocation)) {
            Issue.record(comment, sourceLocation: sourceLocation)
            task.cancel()
        }
    }

    /// The value of `task` within 20 s, or nil with an issue recorded.
    private static func value<T: Sendable>(
        of task: Task<T, Never>, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> T? {
        let box = ValueBox<T>()
        let ended = OneShotGate()
        Task {
            box.set(await task.value)
            await ended.open()
        }
        guard await ended.wait(limit: .seconds(20), sourceLocation: sourceLocation) else {
            task.cancel()
            return nil
        }
        return box.value
    }

    /// A feed over photos that are not on disk, so every coverage scan step probes them.
    /// 2,000 photos of which every second arrives, so each batch completes and half the coverage stays open.
    private static func halfDeliveredUIDs(_ prefix: String) -> (uids: [PhotoUID], payloads: [PhotoUID: Data]) {
        let uids = (0..<2_000).map { Self.uid("\(prefix)-\($0)") }
        let payload = Self.pngData(width: 8, height: 8)
        let payloads = Dictionary(
            uniqueKeysWithValues: uids.enumerated().filter { $0.offset % 2 == 0 }.map { ($0.element, payload) })
        return (uids, payloads)
    }

    #if DEBUG
        /// A foreground feed over `halfDeliveredUIDs(prefix)` whose first coverage step suspends the app.
        private static func suspendingCoverageFeed(
            _ prefix: String
        ) -> (ThumbnailFeedCore, LibraryRuntimeState, Counter, [PhotoUID]) {
            let runtimeState = LibraryRuntimeState(
                initial: LibraryRuntimeSnapshot(executionOpportunity: .foregroundActive))
            let photos = Self.halfDeliveredUIDs(prefix)
            let feed = ThumbnailFeedCore(
                cache: Self.cache(prefix, runtimeState: runtimeState),
                loader: RecordingLoader(payloads: photos.payloads),
                configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 16)
            )
            let steps = Counter()
            let first = FirstCall()
            feed.setCoverageScanStepHookForTesting {
                steps.increment()
                if first.take() { runtimeState.update { $0.executionOpportunity = .suspended } }
            }
            return (feed, runtimeState, steps, photos.uids)
        }
    #endif

    private static func refreshFeed(_ prefix: String) -> (ThumbnailFeedCore, [PhotoUID]) {
        let uids = (0..<2_000).map { Self.uid("\(prefix)-\($0)") }
        let feed = ThumbnailFeedCore(
            cache: Self.cache(prefix), loader: RecordingLoader(), configuration: Self.configuration())
        return (feed, uids)
    }
}

@Suite("MediaFeedCore platform purity")
struct ThumbnailFeedCorePlatformPurityTests {
    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    private var sources: URL {
        packageRoot.appendingPathComponent("Sources/MediaFeedCore")
    }

    private static let forbiddenFrameworkImports: [String] = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "AVKit",
        "MetalKit",
    ]

    private static let forbiddenTokens: [String] = [
        "NSImage",
        "UIImage",
        "NSView",
        "UIView",
        "NSWorkspace",
        "NSOpenPanel",
        "UIApplication",
        "NSApplication",
        "ProcessInfo.processInfo.physicalMemory",
        "ProcessInfo.processInfo.activeProcessorCount",
    ]

    private static let allowedFrameworkImports: Set<String> = [
        "CryptoKit",
        "Foundation",
        "MediaByteCache",
        "MediaDecodingCore",
        "PhotosCore",
    ]

    @Test func hasNoPlatformFrameworkImports() throws {
        let files = try swiftFiles(in: sources)
        #expect(!files.isEmpty)

        var violations: [String] = []
        var seen: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(whereSeparator: { $0.isNewline }) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let remainder = trimmed.dropFirst("import ".count)
                let moduleName = remainder.split(separator: " ").first.map(String.init) ?? String(remainder)
                seen.insert(moduleName)
                if Self.forbiddenFrameworkImports.contains(moduleName) {
                    violations.append("\(file.lastPathComponent): \(trimmed)")
                }
            }
        }

        #expect(
            violations.isEmpty,
            "MediaFeedCore must not import platform UI frameworks:\n\(violations.joined(separator: "\n"))")
        #expect(
            seen.subtracting(Self.allowedFrameworkImports).isEmpty,
            "Unexpected MediaFeedCore imports: \(seen.subtracting(Self.allowedFrameworkImports).sorted())")
    }

    @Test func hasNoPlatformImageOrHardwarePolicyTokens() throws {
        let files = try swiftFiles(in: sources)
        #expect(!files.isEmpty)

        var violations: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in Self.forbiddenTokens where source.contains(token) {
                violations.append("\(file.lastPathComponent): \(token)")
            }
        }

        #expect(
            violations.isEmpty,
            "MediaFeedCore must not reference platform UI types or hardware policy:\n\(violations.joined(separator: "\n"))"
        )
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                !isDirectory.boolValue,
                url.pathExtension == "swift"
            else { continue }
            results.append(url)
        }
        return results.sorted { $0.path < $1.path }
    }
}

private final class LockedAspects: @unchecked Sendable {
    private let lock = NSLock()
    private var aspects: [PhotoUID: CGFloat] = [:]

    func record(_ uid: PhotoUID, aspect: CGFloat) {
        lock.withLock {
            aspects[uid] = aspect
        }
    }

    func value(for uid: PhotoUID) -> CGFloat? {
        lock.withLock { aspects[uid] }
    }
}

private func makeCGImage(width: Int, height: Int) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        pixels[offset] = 160
        pixels[offset + 1] = 90
        pixels[offset + 2] = 50
        pixels[offset + 3] = 255
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func makePNGData(width: Int, height: Int) -> Data {
    let image = makeCGImage(width: width, height: height)
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}
