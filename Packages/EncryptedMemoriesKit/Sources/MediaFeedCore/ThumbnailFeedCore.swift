import CryptoKit
import Foundation
import MediaByteCache
import MediaDecodingCore
import PhotosCore

public enum BackgroundThumbnailDecodeResult: Sendable {
    case decoded(DecodedThumbnail)
    case missing
    case undecodable
}

public struct ThumbnailFeedCoreConfiguration: Sendable, Equatable {
    public let targetPixels: CGFloat
    public let downloadConcurrencyLimit: Int
    public let initialDownloadConcurrency: Int
    public let minimumDownloadConcurrency: Int
    public let batchSize: Int
    public let decodedMemoryBudgetBytes: Int
    public let maxConcurrentDecodes: Int
    public let priorityQueueLimit: Int
    public let sequentialScanLimit: Int
    public let visibleQuietWindow: TimeInterval
    public let crawlBackoffSeconds: TimeInterval
    public let downloadTimeoutSeconds: Double

    public init(
        targetPixels: CGFloat = 320,
        downloadConcurrencyLimit: Int = 4,
        initialDownloadConcurrency: Int? = nil,
        minimumDownloadConcurrency: Int = 1,
        batchSize: Int = 8,
        decodedMemoryBudgetBytes: Int = 128 * 1024 * 1024,
        maxConcurrentDecodes: Int = 2,
        priorityQueueLimit: Int = 600,
        sequentialScanLimit: Int = 128,
        visibleQuietWindow: TimeInterval = 0.25,
        crawlBackoffSeconds: TimeInterval = 5,
        downloadTimeoutSeconds: Double = 20
    ) {
        let downloadLimit = max(1, downloadConcurrencyLimit)
        let minimum = min(max(1, minimumDownloadConcurrency), downloadLimit)
        let initial = initialDownloadConcurrency ?? max(minimum, downloadLimit / 2)
        self.targetPixels = max(1, targetPixels)
        self.downloadConcurrencyLimit = downloadLimit
        self.initialDownloadConcurrency = min(max(minimum, initial), downloadLimit)
        self.minimumDownloadConcurrency = minimum
        self.batchSize = max(1, batchSize)
        self.decodedMemoryBudgetBytes = max(1, decodedMemoryBudgetBytes)
        self.maxConcurrentDecodes = max(1, maxConcurrentDecodes)
        self.priorityQueueLimit = max(1, priorityQueueLimit)
        self.sequentialScanLimit = max(1, sequentialScanLimit)
        self.visibleQuietWindow = max(0, visibleQuietWindow)
        self.crawlBackoffSeconds = max(0, crawlBackoffSeconds)
        self.downloadTimeoutSeconds = max(0.1, downloadTimeoutSeconds)
    }
}

public protocol ThumbnailCoverageCheckpointStore: Sendable {
    func loadPresent(_ candidates: [PhotoUID], for key: String) -> Set<PhotoUID>
    func recordPresent(_ uids: [PhotoUID], for key: String)
    func recordMissing(_ uids: [PhotoUID], for key: String)
}

/// Handle to one feed arrival-wake subscription. The registration is safe to end from any executor and is
/// idempotent, so a platform host can release its observer during deterministic teardown without racing a wake.
public final class ThumbnailFeedWakeRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var cancel: (() -> Void)?

    fileprivate init(cancel: @escaping () -> Void) {
        self.cancel = cancel
    }

    /// Remove only this observer. Calling `end()` more than once has no effect.
    public func end() {
        let action = lock.withLock {
            defer { cancel = nil }
            return cancel
        }
        action?()
    }

    deinit { end() }
}

public final class FileThumbnailCoverageCheckpointStore: ThumbnailCoverageCheckpointStore, @unchecked Sendable {
    private let directory: URL
    private let scope: String
    private let tokenScope: String
    private let lock = NSLock()
    private var loaded: [String: Set<String>] = [:]

    public init(directory: URL, scope: String) {
        self.directory = directory
        self.scope = Self.safeComponent(scope)
        self.tokenScope = scope
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func loadPresent(_ candidates: [PhotoUID], for key: String) -> Set<PhotoUID> {
        lock.withLock {
            let pathKey = scopedKey(key)
            let fileURL = url(for: pathKey)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                loaded[pathKey] = []
                return []
            }
            let tokens: Set<String>
            if let cached = loaded[pathKey] {
                tokens = cached
            } else {
                let state = read(from: fileURL)
                tokens = state.tokens
                loaded[pathKey] = tokens
                let redundantHistory = state.lineCount > max(1_024, tokens.count * 2)
                if redundantHistory {
                    writeSnapshot(tokens, to: fileURL)
                }
            }
            return Set(candidates.filter { tokens.contains(token(for: $0, key: key)) })
        }
    }

    public func recordPresent(_ uids: [PhotoUID], for key: String) {
        record(uids, key: key, present: true)
    }

    public func recordMissing(_ uids: [PhotoUID], for key: String) {
        record(uids, key: key, present: false)
    }

    private func record(_ uids: [PhotoUID], key: String, present: Bool) {
        guard !uids.isEmpty else { return }
        lock.withLock {
            let pathKey = scopedKey(key)
            let fileURL = url(for: pathKey)
            let state =
                loaded[pathKey].map {
                    ReadState(tokens: $0, lineCount: $0.count)
                } ?? read(from: fileURL)
            var known = state.tokens
            let changed: [String]
            if present {
                changed = uids.map { token(for: $0, key: key) }.filter { known.insert($0).inserted }
            } else {
                changed = uids.map { token(for: $0, key: key) }.filter { known.remove($0) != nil }
            }
            guard !changed.isEmpty else {
                loaded[pathKey] = known
                return
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let lines = changed.map { Self.line(for: $0, present: present) }.joined()
            if let data = lines.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: fileURL.path),
                    let handle = try? FileHandle(forWritingTo: fileURL)
                {
                    do {
                        try handle.seekToEnd()
                        try handle.write(contentsOf: data)
                        try handle.close()
                    } catch {
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: fileURL, options: .atomic)
                }
            }
            loaded[pathKey] = known
        }
    }

    private func scopedKey(_ key: String) -> String {
        "\(scope)-\(Self.safeComponent(key))"
    }

    private func url(for scopedKey: String) -> URL {
        directory.appendingPathComponent(scopedKey).appendingPathExtension("log")
    }

    private struct ReadState {
        var tokens: Set<String>
        var lineCount: Int
    }

    private func read(from url: URL) -> ReadState {
        guard let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else {
            return ReadState(tokens: [], lineCount: 0)
        }
        var tokens: Set<String> = []
        var lineCount = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            lineCount += 1
            guard parts.count == 2, parts[0] == "H" || parts[0] == "M" else { continue }
            let token = String(parts[1])
            if parts[0] == "H" { tokens.insert(token) } else { tokens.remove(token) }
        }
        return ReadState(tokens: tokens, lineCount: lineCount)
    }

    private static func line(for token: String, present: Bool) -> String {
        "\(present ? "H" : "M")\t\(token)\n"
    }

    private func writeSnapshot(_ tokens: Set<String>, to url: URL) {
        let text = tokens.sorted().map { Self.line(for: $0, present: true) }.joined()
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    private func token(for uid: PhotoUID, key: String) -> String {
        let material = "\(tokenScope)\u{1f}\(key)\u{1f}\(uid.volumeID)\u{1f}\(uid.nodeID)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return Self.lowercaseHex(digest)
    }

    private static let lowercaseHexDigits = Array("0123456789abcdef".utf8)

    private static func lowercaseHex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var output: [UInt8] = []
        output.reserveCapacity(64)
        for byte in bytes {
            output.append(lowercaseHexDigits[Int(byte >> 4)])
            output.append(lowercaseHexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func safeComponent(_ value: String) -> String {
        let cleaned = value.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
        }.joined()
        return String(cleaned.prefix(180))
    }
}

/// Revocable access to one photo on a foreground surface. It never changes the library grid's authorization.
public final class VisibleThumbnailAccess: @unchecked Sendable {
    fileprivate let id: UUID
    fileprivate let uid: PhotoUID
    fileprivate let owner: UUID
    fileprivate let cacheGeneration: CacheWriterGeneration.Token
    private let authorized: @Sendable () -> Bool
    private let lock = NSLock()
    private var active = true
    private let current: @Sendable () -> Bool
    private let onEnd: @Sendable () -> Void

    fileprivate init(
        id: UUID, uid: PhotoUID, owner: UUID, cacheGeneration: CacheWriterGeneration.Token,
        authorized: @escaping @Sendable () -> Bool, current: @escaping @Sendable () -> Bool,
        onEnd: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.uid = uid
        self.owner = owner
        self.cacheGeneration = cacheGeneration
        self.authorized = authorized
        self.current = current
        self.onEnd = onEnd
    }

    fileprivate var isAuthorized: Bool { lock.withLock { active } && authorized() }
    fileprivate var isCurrent: Bool { isAuthorized && current() }

    public func end() {
        let ended = lock.withLock {
            defer { active = false }
            return active
        }
        if ended { onEnd() }
    }

    deinit { end() }
}

/// A stop invalidates foreground capabilities synchronously; cancellation does not need an actor hop to revoke them.
private final class VisibleThumbnailLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var open: [UUID: PhotoUID] = [:]
    func capture() -> UInt64 { lock.withLock { generation } }
    func isCurrent(_ value: UInt64) -> Bool { lock.withLock { generation == value } }
    func invalidate() { lock.withLock { generation &+= 1 } }
    func opened(_ id: UUID, for uid: PhotoUID) { lock.withLock { open[id] = uid } }
    func ended(_ id: UUID) { lock.withLock { _ = open.removeValue(forKey: id) } }
    var openUIDs: [PhotoUID] { lock.withLock { Array(open.values) } }
}

/// Universal thumbnail pipeline core.
///
/// Owns platform-independent feed behavior: disk/network decisions, priority ordering, background crawl,
/// adaptive download concurrency, decoded `CGImage` residency, and diagnostics. Platform targets adapt
/// `DecodedThumbnail` to their presentation image type outside this module.
public actor ThumbnailFeedCore {
    private struct PriorityReservation: Sendable {
        let uid: PhotoUID
        var priority: ThumbnailPriority
        let generation: UInt64
    }

    private nonisolated let cache: ThumbnailCache
    private nonisolated let resourceCoordinator: LibraryResourceCoordinator
    private nonisolated let visibleAccessOwner = UUID()
    private nonisolated let visibleAccessLifetime = VisibleThumbnailLifetime()
    private nonisolated let loader: ThumbnailBatchLoader
    private nonisolated let onDecoded: @Sendable (PhotoUID, DecodedThumbnail) -> Void
    private nonisolated let decoded: DecodedThumbnailCache
    private nonisolated let diskPresence = DiskPresenceCache()
    /// Thumbnail reads are authorized by the thumbnail retention scope: every accessible thumbnail-capable
    /// identity plus the burst members they own. Burst members are not library items, so the analysis scope
    /// alone refused a series filmstrip even though its bytes are retained on disk.
    private nonisolated let thumbnailReadAuthorization =
        DerivedDataResourceAuthorization<ThumbnailRetentionDerivedDataScopeKind>()
    /// Local pending photos are not in any source scope; the host authorizes them explicitly.
    private nonisolated let localAuthorization = LocalThumbnailAuthorization()
    /// Proton photos that took over a pending tile. The grid lists them as soon as the timeline does, but the
    /// source scope follows asynchronously; until it covers them, the handed-over image keeps them readable, so
    /// the tile never turns black at the handover.
    private nonisolated let adoptedAuthorization = LocalThumbnailAuthorization()
    private static let maxAdoptedWithoutScope = 1_024
    private static let maxLocalPreload = 24
    private var localLoader: (any LocalThumbnailLoading)?
    /// Queued local demand in request order. A newer viewport replaces it; warm passes append.
    private var localDemand: [(uid: PhotoUID, pixels: Int)] = []
    /// Device loads that run now. Each publishes on its own, so one slow iCloud download never holds back
    /// the others. `pinned` loads have a caller that waits for them; a viewport change never cancels those.
    private var localLoads: [PhotoUID: (id: UUID, pinned: Bool, task: Task<Void, Never>)] = [:]
    private static let maxLocalLoads = 4
    /// Local photos requested before the host authorized them. They load as soon as authorization arrives, so
    /// a grid that published its presentation first never keeps blank tiles.
    private var deniedLocalDemand: [PhotoUID: Int] = [:]
    private static let maxDeniedLocalDemand = 2_048
    /// Failed local loads (offline iCloud, a deleted asset). The photo shows a placeholder and is tried again
    /// after 30 s, doubling to at most 10 min, and only when a grid asks for it again.
    private var localFailedAttempts: [PhotoUID: Int] = [:]
    private var localRetryAt: [PhotoUID: ContinuousClock.Instant] = [:]
    private var localRetryTask: (due: ContinuousClock.Instant, task: Task<Void, Never>)?
    /// Advances when the feed stops, so a waiting direct caller never starts a load after teardown.
    private var localGeneration: UInt64 = 0
    private nonisolated let configuration: ThumbnailFeedCoreConfiguration
    private nonisolated let coverageStore: (any ThumbnailCoverageCheckpointStore)?
    private nonisolated let diagnostics: PhotoDiagnostics

    private var priority: [PhotoUID] = []
    private var priorityByUID: [PhotoUID: ThumbnailPriority] = [:]
    /// Priority items removed from the queue while their disk presence or network load is in flight. A crawl
    /// restart restores these before cancelling the old generation, so first-visible work cannot disappear.
    private var priorityReservations: [PriorityReservation] = []
    private var sequential: [PhotoUID] = []
    private var sequentialIndex = 0
    private var workersRunning = false
    private var workerTask: Task<Void, Never>?
    /// The fixed crawl workers are retained separately so restart/teardown can cancel each task directly.
    /// `workerTask` aggregates their completion and remains the single join handle.
    private var workerTasks: [Task<Void, Never>] = []
    /// Cancelled workers retained until an explicit owner teardown joins them. Ordinary cache clears
    /// stay generation-fenced and non-blocking, while retry/sign-out can establish a hard ownership boundary.
    private var retiredWorkerTasks: [Task<Void, Never>] = []
    /// Explicit user interaction (scroll/pinch/drag), separate from viewport warm requests. Stored
    /// outside actor isolation so shared workload governors can make a synchronous scheduling decision.
    private nonisolated let interactionState = InteractionStateBox()
    private var decodeInFlight = 0
    /// Feed-wide admission for decrypt + image decode. The actual blocking Foundation/CryptoKit/ImageIO work
    /// runs on `decodeExecutor`, never on Swift's cooperative executor.
    private let decodePermits: DecodePermitPool
    private let decodeExecutor: ThumbnailDecodeWorkExecutor
    /// A lock-backed latest-value ingress lets AppKit publish every viewport synchronously without creating
    /// one unstructured actor task per display tick. Exactly one actor drain is scheduled at a time; skipped
    /// intermediate generations were never visible long enough to deserve disk work.
    private nonisolated let visibleDiskDemandInbox = LatestVisibleDecodeDemandInbox()
    /// Stable network intent survives source maintenance independently of the moving disk viewport.
    private var visiblePriorityDemand: [PhotoUID]?
    /// One long-lived latest-demand queue serves moving viewports. Replacing the viewport drops only pending
    /// stale work; already-running synchronous reads finish in their existing lanes and workers then pull from
    /// the newest generation. This prevents cancelled per-viewport task groups from accumulating blockers.
    private var visibleDiskDemand = LatestVisibleDecodeDemand()
    private var visibleDiskWorkerCount = 0
    private var visibleDiskWorkerTasks: [UUID: Task<Void, Never>] = [:]
    private var retiredVisibleDiskWorkerTasks: [Task<Void, Never>] = []
    /// Reserved crawl/priority candidates whose encrypted presence is being checked off actor. Coverage cannot
    /// be declared settled until these reservations return, even if their source queues are already empty.
    private var diskProbeBatchesInFlight = 0
    private var downloadInFlight = 0
    /// The photos of each crawl batch that is downloading, by batch. Only `loadDirectDecoded` reads it, to count
    /// a direct load that overlaps a batch (`thumb.directLoadOverlapsBatch`). It never delays a load.
    private var batchesInFlight: [UUID: Set<PhotoUID>] = [:]
    private var lastErrors: [String] = []
    private var prefetchEnabled = true
    private var prefetchPaused = false
    /// Wakes the crawl after storage leaves the critical level. It exists only while the crawl sleeps for storage.
    /// Wakes the crawl when the condition that held it ends: storage recovers, or the app is in the foreground.
    private var crawlWakeTask: Task<Void, Never>?
    /// The workers' waits for the coordinator's permit in a background window.
    private var windowPermitWaits: [UUID: Task<LibraryBackgroundWindowPermit?, Never>] = [:]
    private var sourceEpoch: LibrarySourceEpoch?
    private var lastSelectedScope: SelectedDerivedDataScope?
    private var lastAnalysisScope: AnalysisDerivedDataScope?
    private var lastRetentionScope: ThumbnailRetentionDerivedDataScope?
    private var sourceReconciliationInFlight = false
    private var highestSourceReconciliationRevision: UInt64?
    private struct SourceReconciliationRequest {
        let selectedScope: SelectedDerivedDataScope
        let analysisScope: AnalysisDerivedDataScope
        let retentionScope: ThumbnailRetentionDerivedDataScope
    }
    private struct SourceReconciliationWaiter {
        let revision: UInt64
        let continuation: CheckedContinuation<MediaCacheReconciliationResult, Never>
    }
    /// Reentrant callers publish only the newest accepted revision while the current worker join drains.
    /// Authorization is applied before queuing, so an older crawl cannot serve a newly excluded resource.
    private var pendingSourceReconciliation: SourceReconciliationRequest?
    private var sourceReconciliationWaiters: [SourceReconciliationWaiter] = []
    private let coverageCheckpointKey = "thumbnail-coverage-v1"
    private var checkpointPresent: Set<PhotoUID> = []
    /// Persisted coverage is an advisory write-suppression hint only. It never skips the first authenticated
    /// probe of a fresh crawl; `checkpointPresent` contains only hits returned by the current probe executor.
    private var checkpointHints: Set<PhotoUID> = []
    /// Forces one authenticated probe for every UID in a fresh crawl before normal validated-presence fast paths
    /// resume. This protects startup against a corrupted blob whose filename remains in the in-process proof set.
    private var startupAuthenticationPending = false
    /// Set once a crawl of this feed authenticated every thumbnail it queued. A source change restarts the crawl,
    /// for example after each upload; the restart then checks proven blobs with a file lookup instead of reading
    /// and decrypting every cached thumbnail again. New blobs are still authenticated on their first probe.
    private var authenticatedCrawlCompleted = false
    /// Coalesces durable coverage updates so a first crawl does not open the checkpoint file once per tiny
    /// network batch. Losing the final unflushed block on process termination is safe: blobs remain on disk and
    /// are verified again on the next crawl.
    private var pendingCheckpointUpdates: [PhotoUID: Bool] = [:]
    private static let checkpointFlushThreshold = 128
    /// Invalidates asynchronous checkpoint bootstraps and worker groups across timeline/account changes.
    private var prefetchGeneration: UInt64 = 0
    /// Main-projection identities used by diagnostics. The crawl may also contain analysis-only identities.
    private var prefetchReportingUIDs: Set<PhotoUID>?
    private var prefetchCompleted = 0
    private var prefetchFailed = 0
    private var prefetchFailedTimeout = 0
    private var prefetchFailedBatchError = 0
    private var prefetchFailedItemError = 0
    private var prefetchFailedUnreported = 0
    private var prefetchFailedWithheld = 0
    /// Photos withheld after an authorization change, which the crawl requests again behind its own gates (pause,
    /// backoff, visible demand, storage pressure), and how often each was requeued in this crawl. The bound keeps
    /// churn from looping forever.
    private var withheldRetry: [PhotoUID] = []
    private var withheldRequeues: [PhotoUID: Int] = [:]
    private static let maxWithheldRequeues = 3
    private var prefetchDiskHit = 0
    private var prefetchDownloadStarted = 0
    private var prefetchDownloadCompleted = 0
    private var prefetchDecodeStarted = 0
    private var prefetchDecodeCompleted = 0
    /// UIDs whose thumbnail the backend refused per item (e.g. "no thumbnail"). Quarantined so the
    /// crawl doesn't re-request them every batch; cleared by `startPrefetch` so a fresh crawl
    /// (new session, timeline refresh) retries them exactly once. A photo that joined moments ago may not be
    /// downloadable yet; its refusal lapses after `recentJoinRefusalLapse`, so visible demand asks again.
    private nonisolated let unfetchable: UnfetchableThumbnailBox
    static let recentJoinRefusalWindow: TimeInterval = 120
    static let recentJoinRefusalLapse: TimeInterval = 10
    static let maxRecentJoinRefusalLapses = 5
    /// The membership last published to this feed. The first one is the baseline; photos that join later are
    /// recorded in `unfetchable`.
    private var knownMembership: Set<PhotoUID>?
    /// Wakes the hosts when a refusal lapses, so an idle grid asks for its visible tiles again.
    private var refusalLapseWake: (due: Date, task: Task<Void, Never>)?
    private var skippedUnfetchable = 0
    private var lastRepassPercent = -1.0
    /// Cursor + one-shot completion flag for the bounded end-of-crawl disk-coverage re-scan
    /// (`advanceDiskCoverageScan`). Reset per crawl in `startPrefetch`.
    private var coverageScanCursor = 0
    private var coverageSettled = false
    /// Single-flight guard for `runCoverageRefresh`; only one worker refreshes coverage at a time.
    private var coverageRefreshInFlight = false
    private var coverageRefreshStarts = 0
    /// How often the workers started, so a test can prove that a held crawl does not poll.
    private var workerStarts = 0
    /// How many coverage refreshes ran an actual chunked `cache.has` sweep instead of settling from known state.
    private var coverageFullScans = 0
    /// Mirrors the cache session generation so account changes invalidate presence knowledge, while ordinary
    /// crawl starts retain the UID-keyed values for overlapping timeline items.
    private var diskPresenceGeneration: CacheWriterGeneration.Token
    /// Stable lease for this feed owner. A feed created for account A must fail closed after the shared cache
    /// is configured for account B, including late RAM decode publication.
    private nonisolated let ownerSessionLease: CacheWriterGeneration.SessionToken
    private var targetConcurrency = 2
    private var activeDownloaders = 0
    /// SDK thumbnail enumeration cannot currently be cancelled through its public facade. Timed-out loader
    /// tasks therefore continue to occupy a concurrency slot until they actually return, preventing an
    /// unbounded accumulation of hidden network/crypto work during an outage.
    private var timedOutLoaders = 0
    /// Completion trackers for timed-out SDK loaders. Owner teardown joins these tasks before it releases
    /// the backend, even when the SDK operation ignored the crawl worker's cancellation.
    private var timedOutLoaderTasks: [UUID: Task<Void, Never>] = [:]
    private var nextDirectDecodeFlightID: UInt64 = 0
    private struct DirectDecodeKey: Hashable {
        let uid: PhotoUID
        let accessID: UUID?
    }
    private var directDecodeFlights: [DirectDecodeKey: DirectDecodeFlight] = [:]
    /// Direct visible loads became feed-owned when exact-UID requests were coalesced. Retain cancelled flights
    /// until teardown joins them, just like cancellation-ignoring crawl loaders.
    private var retiredDirectDecodeTasks: [Task<DecodedThumbnail?, Never>] = []
    private var aimdSuccessStreak = 0
    #if DEBUG
        private var lastPrefetchSummaryAt: Date?
        private var lastPrefetchSummaryWasActive = false
        private var lastPrefetchSummaryPausedReason: String?
    #endif

    private nonisolated let clock: @Sendable () -> Date
    /// Last visible-demand timestamp. Held in a `nonisolated`, lock-guarded box (not actor state) so
    /// `noteVisibleDemand` can record demand without queuing behind the crawl on the serial actor - the crawl
    /// workers read it `nonisolated` too, so they back off the instant a viewport goes live even while one of
    /// them is mid-scan. If this were actor state the demand signal would starve on the same queue as the
    /// `warmDecoded` it is meant to unblock (the cold-start bug).
    private nonisolated let lastDemand = LastDemandBox()
    private var crawlBackoffUntil: Date?

    /// Fired (on the feed actor) after a thumbnail becomes usable while a viewport is live - the "images
    /// available" signal grid hosts subscribe to so they redraw without needing a scroll nudge. Background
    /// downloads first land bytes on disk; visible disk decodes also use this wake once their image enters RAM.
    /// This is the platform-neutral analogue of the macOS `MetalGridDataSource.onImagesAvailable` wake: the
    /// crawl worker stores network arrivals to disk only, so without this signal a host that has gone idle (or
    /// whose visible warm set is unchanged) never learns the bytes arrived. Each platform host owns one token.
    private nonisolated let imagesAvailableWake = ImagesAvailableWakeBox()
    private nonisolated let cacheArrivalWake = ImagesAvailableWakeBox()
    #if DEBUG
        /// Deterministic test-only gate for a disk probe. It is absent from release builds.
        private nonisolated let testingHooks = ThumbnailFeedCoreTestingHooks()
        private var downloadSlotWaitHookForTesting: (@Sendable () -> Void)?
        private var windowPermitReturnHookForTesting: (@Sendable () async -> Void)?
    #endif

    public init(
        cache: ThumbnailCache,
        loader: ThumbnailBatchLoader,
        configuration: ThumbnailFeedCoreConfiguration = ThumbnailFeedCoreConfiguration(),
        coverageStore: (any ThumbnailCoverageCheckpointStore)? = nil,
        diagnostics: PhotoDiagnostics = .shared,
        clock: @escaping @Sendable () -> Date = { Date() },
        resourceCoordinator: LibraryResourceCoordinator = .shared,
        onDecoded: @escaping @Sendable (PhotoUID, DecodedThumbnail) -> Void = { _, _ in }
    ) {
        self.cache = cache
        self.resourceCoordinator = resourceCoordinator
        self.loader = loader
        self.configuration = configuration
        self.coverageStore = coverageStore
        self.diagnostics = diagnostics
        self.clock = clock
        self.unfetchable = UnfetchableThumbnailBox(clock: clock)
        self.onDecoded = onDecoded
        self.decoded = DecodedThumbnailCache(costLimit: configuration.decodedMemoryBudgetBytes)
        self.decodePermits = DecodePermitPool(permits: configuration.maxConcurrentDecodes)
        self.decodeExecutor = ThumbnailDecodeWorkExecutor()
        let leases = cache.captureLeases()
        self.ownerSessionLease = leases.session
        self.diskPresenceGeneration = leases.writer
        targetConcurrency = configuration.initialDownloadConcurrency
    }

    private nonisolated func ownerLeaseIsCurrent() -> Bool {
        cache.isCurrentSessionLease(ownerSessionLease)
    }

    /// Subscribe to the "images available" wake (see `onImagesAvailable`). The callback fires after source
    /// admission or when a thumbnail becomes available while a viewport is recently live; the host hops to its own
    /// actor and redraws / re-warms. Registration is synchronous with respect to the nonisolated wake box, so a
    /// first visible viewport cannot miss a tiny cached arrival while an actor task is still queued.
    @discardableResult
    public func setOnImagesAvailable(_ callback: (@Sendable () -> Void)?) -> ThumbnailFeedWakeRegistration {
        guard let callback else { return ThumbnailFeedWakeRegistration(cancel: {}) }
        return imagesAvailableWake.add(callback)
    }

    /// Nonisolated adapter for platform hosts. The wake itself is owned by `ThumbnailFeedCore`; AppKit/UIKit
    /// facades expose only `feedCore`, then subscribe through this shared entry point instead of carrying
    /// duplicate fire-and-forget actor-hop code. The returned token removes only this subscriber.
    @discardableResult
    public nonisolated func setOnImagesAvailableWake(
        _ callback: @escaping @Sendable () -> Void
    ) -> ThumbnailFeedWakeRegistration {
        imagesAvailableWake.add(callback)
    }

    /// Fires when downloaded thumbnail bytes become durable in the encrypted cache. Unlike the grid wake,
    /// this remains active during a background crawl so cache-backed consumers can resume immediately.
    @discardableResult
    public nonisolated func setOnCacheArrivalWake(
        _ callback: @escaping @Sendable () -> Void
    ) -> ThumbnailFeedWakeRegistration {
        return cacheArrivalWake.add(callback)
    }

    /// A generous "a live viewport is (or was very recently) waiting on content" gate for the arrival wake: wide
    /// enough to span a slow network delivery (bounded by the download timeout), so a tile that lands seconds
    /// after its warm still wakes the grid, yet closed when no viewport has demanded anything recently, so a
    /// purely background crawl (user not looking) never spins the host's display loop.
    private nonisolated func hostArrivalWakeIsLive(now: Date) -> Bool {
        guard let last = lastDemand.get() else { return false }
        return now.timeIntervalSince(last) < configuration.downloadTimeoutSeconds + 5
    }

    /// Governor-driven memory-pressure response for the decoded-thumbnail RAM tier. `scale` lowers the
    /// cost budget (evicting LRU entries down to it); `purge` drops everything held now (the UIKit
    /// `didReceiveMemoryWarning` / critical semantic). `nonisolated` + internally lock-guarded, so the
    /// governor calls it without hopping the feed actor (never blocks visible-tile decodes). Restoring
    /// `scale: 1.0, purge: false` returns the full budget. The disk tier is untouched - nothing is lost,
    /// only re-decoded on demand.
    public nonisolated func applyDecodedMemoryPressure(scale: Double, purge: Bool) {
        let clamped = min(1, max(0, scale))
        decoded.setCostLimit(max(1, Int(Double(configuration.decodedMemoryBudgetBytes) * clamped)))
        if purge { decoded.removeAll() }
        // Eviction is not completed viewport work. Permit the next host demand to retry, without
        // immediately refilling memory while the governor is asking consumers to release it.
        visibleDiskDemandInbox.invalidate()
    }

    /// The Duplicates surface has independently verified its group members. Grant only its visible tile,
    /// and revoke the capability on disappearance, feed stop, cache clear or account transition.
    public nonisolated func beginVisibleThumbnailAccess(for uid: PhotoUID) -> VisibleThumbnailAccess {
        let id = UUID()
        let generation = cache.captureWriterGeneration()
        let lifetime = visibleAccessLifetime.capture()
        visibleAccessLifetime.opened(id, for: uid)
        return VisibleThumbnailAccess(
            id: id, uid: uid, owner: visibleAccessOwner, cacheGeneration: generation,
            authorized: { [visibleAccessLifetime] in visibleAccessLifetime.isCurrent(lifetime) },
            current: { [self] in ownerLeaseIsCurrent() && cache.isCurrentWriterGeneration(generation) },
            onEnd: { [visibleAccessLifetime] in visibleAccessLifetime.ended(id) })
    }

    /// The photos whose foreground access no surface has ended yet, including accesses that a stop or a cache clear
    /// already revoked. A surface that left the screen must not appear here.
    public nonisolated var openVisibleThumbnailAccessUIDs: [PhotoUID] { visibleAccessLifetime.openUIDs }

    public func cachedDecoded(for uid: PhotoUID, access: VisibleThumbnailAccess? = nil) async -> DecodedThumbnail? {
        guard readAllowed(uid, access: access) else { return nil }
        guard ownerLeaseIsCurrent() else {
            decoded.removeAll()
            return nil
        }
        if let cached = decoded.image(for: uid) {
            diagnostics.increment("thumb.ramDecodedHit")
            return cached
        }
        // Local pending photos live in memory only.
        guard !uid.isLocalPending else { return nil }
        diagnostics.increment("thumb.ramDecodeMiss")
        diagnostics.recordDiskReadDuringPinch()
        let cache = self.cache
        let generation = access?.cacheGeneration ?? cache.captureWriterGeneration()
        let maxPixels = configuration.targetPixels
        let result = await decodeExecutor.perform(priority: .visibleNow) { () -> (Bool, DecodedThumbnail?) in
            // The library grid keeps the cache's own retention check; only a foreground access replaces it.
            let data: Data?
            if let access {
                data = cache.diskData(
                    for: uid, ifCurrent: generation, authorizing: { [self] in cacheReadAuthorized(uid, access: access) }
                )
            } else {
                data = cache.diskData(for: uid)
            }
            guard let data else { return (false, nil) }
            return (true, ThumbnailImageDecoder.downsample(data, maxPixelSize: maxPixels))
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
            decoded.removeAll()
            return nil
        }
        guard readAllowed(uid, access: access) else { return nil }
        if result.0 {
            diskPresence.set(uid, present: true)
            diagnostics.increment("thumb.diskCacheHit")
            guard let image = result.1 else {
                diagnostics.increment("thumb.diskDecodeFailed")
                recordError("decode failed for \(Self.key(uid))")
                return nil
            }
            return storeDecoded(image, for: uid, decodePixelCap: Int(configuration.targetPixels), access: access)
        }
        diskPresence.set(uid, present: false)
        diagnostics.increment("thumb.diskCacheMiss")
        return nil
    }

    /// Cache-only decode for low-priority consumers such as local ML indexing.
    ///
    /// Disk I/O, decryption and image decode run away from the serial feed actor, so indexing
    /// cannot delay visible-grid scheduling. One-shot ML decodes do not enter the grid's decoded
    /// LRU or emit redraw callbacks. A miss never starts a network request; the caller can retry
    /// after the normal thumbnail crawl has populated the encrypted disk tier.
    public nonisolated func backgroundCachedDecoded(for uid: PhotoUID) async -> DecodedThumbnail? {
        guard case .decoded(let image) = await backgroundThumbnailDecodeResult(for: uid) else { return nil }
        return image
    }

    /// Source-aware direct decode for an explicitly visible analysis-only surface, such as an additional
    /// collection cover. It never publishes into the main grid's decoded LRU.
    public func analysisDecoded(for uid: PhotoUID) async -> DecodedThumbnail? {
        guard ownerLeaseIsCurrent(), readAllowed(uid) else { return nil }
        if case .decoded(let cached) = await backgroundThumbnailDecodeResult(for: uid) {
            return cached
        }
        guard !unfetchable.contains(uid) else { return nil }

        let cache = self.cache
        let generation = cache.captureWriterGeneration()
        let buffer = ByteBox()
        let result: ThumbnailBatchLoadResult
        if let priorityLoader = loader as? any PriorityThumbnailBatchLoader {
            result = await priorityLoader.loadThumbnails(for: [uid], priority: .visibleNow) { loadedUID, data in
                if loadedUID == uid { buffer.set(data) }
            }
        } else {
            result = await loader.loadThumbnails(for: [uid]) { loadedUID, data in
                if loadedUID == uid { buffer.set(data) }
            }
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation),
            readAllowed(uid)
        else { return nil }
        guard let data = buffer.value else {
            if result.itemErrors[uid] != nil {
                scheduleRefusalLapseWake(unfetchable.insert(uid))
            } else if result.withheldUIDs.contains(uid) {
                recordError("thumbnail withheld for \(Self.key(uid)) after an authorization change")
            }
            return nil
        }
        let maxPixels = configuration.targetPixels
        let decoded: DecodedThumbnail? = await decodeExecutor.perform(priority: .visibleNow) {
            let stored = cache.storeToDisk(data, for: uid, ifCurrent: generation)
            guard stored == .stored || stored == .storagePaused else { return nil }
            return ThumbnailImageDecoder.downsample(data, maxPixelSize: maxPixels)
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation),
            readAllowed(uid)
        else { return nil }
        return decoded
    }

    /// A derived consumer retaining decoded pixels must validate the same account, cache epoch
    /// and analysis access as a fresh decode. It must not turn its own cache into an access bypass.
    package nonisolated func analysisThumbnailLease(for uid: PhotoUID) -> (@Sendable () -> Bool)? {
        let generation = cache.captureWriterGeneration()
        let isCurrent: @Sendable () -> Bool = { [self] in
            ownerLeaseIsCurrent() && cache.isCurrentWriterGeneration(generation)
                && readAllowed(uid)
        }
        return isCurrent() ? isCurrent : nil
    }

    /// Detailed cache-only result for background consumers that must distinguish a thumbnail
    /// that may still arrive from bytes that are present but cannot be decoded.
    public nonisolated func backgroundThumbnailDecodeResult(for uid: PhotoUID) async -> BackgroundThumbnailDecodeResult
    {
        guard readAllowed(uid) else { return .missing }
        let cache = self.cache
        let generation = cache.captureWriterGeneration()
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
            decoded.removeAll()
            return .missing
        }
        guard readAllowed(uid) else { return .missing }
        if let image = decoded.image(for: uid) {
            guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
                decoded.removeAll()
                return .missing
            }
            guard readAllowed(uid) else { return .missing }
            return .decoded(image)
        }

        let maxPixels = configuration.targetPixels
        let result = await Task.detached(priority: .utility) { () -> (dataPresent: Bool, image: DecodedThumbnail?) in
            guard let data = cache.diskData(for: uid) else { return (false, nil) }
            return (true, ThumbnailImageDecoder.downsample(data, maxPixelSize: maxPixels))
        }.value
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
            decoded.removeAll()
            return .missing
        }
        guard readAllowed(uid) else { return .missing }
        guard result.dataPresent else {
            guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
                decoded.removeAll()
                return .missing
            }
            guard readAllowed(uid) else { return .missing }
            diskPresence.set(uid, present: false)
            guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
                decoded.removeAll()
                return .missing
            }
            guard readAllowed(uid) else { return .missing }
            return .missing
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
            decoded.removeAll()
            return .missing
        }
        guard readAllowed(uid) else { return .missing }
        diskPresence.set(uid, present: true)
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
            decoded.removeAll()
            return .missing
        }
        guard readAllowed(uid) else { return .missing }
        guard let image = result.image else {
            guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
                decoded.removeAll()
                return .missing
            }
            guard readAllowed(uid) else { return .missing }
            return .undecodable
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
            decoded.removeAll()
            return .missing
        }
        guard readAllowed(uid) else { return .missing }
        return .decoded(image)
    }

    public nonisolated func memoryDecoded(for uid: PhotoUID, access: VisibleThumbnailAccess? = nil) -> DecodedThumbnail?
    {
        guard ownerLeaseIsCurrent() else {
            decoded.removeAll()
            return nil
        }
        guard readAllowed(uid, access: access) else { return nil }
        return decoded.image(for: uid)
    }

    /// True when the RAM tier holds this UID but at a decode cap materially below `pixels` - i.e. a warm
    /// at `pixels` would actually produce a sharper image. False when the entry is absent (that is the
    /// ordinary missing-tile path) or already adequate, so a settled render loop that keys retry work on
    /// this can never spin on a source-limited image.
    public nonisolated func decodedNeedsSharperSource(_ uid: PhotoUID, forPixels pixels: Int) -> Bool {
        guard ownerLeaseIsCurrent(), readAllowed(uid) else { return false }
        return decoded.needsSharperDecode(for: uid, requestedPixels: pixels)
    }

    /// Ordinary warm consumers retain the configured decode target as their floor. `0` means no size opinion.
    private func effectiveDecodePixels(for request: ThumbnailRequest) -> CGFloat {
        guard request.pixelSize > 0 else { return configuration.targetPixels }
        return max(CGFloat(request.pixelSize), configuration.targetPixels)
    }

    /// The latest viewport owns its measured upload size, avoiding a larger transient RAM decode.
    private func visibleDecodePixels(for request: ThumbnailRequest) -> CGFloat {
        request.pixelSize > 0 ? max(1, CGFloat(request.pixelSize)) : configuration.targetPixels
    }

    public nonisolated func isKnownUnfetchable(_ uid: PhotoUID) -> Bool {
        isKnownUnfetchable(uid, access: nil)
    }

    /// A foreground surface asks with its own access, so a photo outside the library inventory can end its load.
    public nonisolated func isKnownUnfetchable(_ uid: PhotoUID, access: VisibleThumbnailAccess?) -> Bool {
        readAllowed(uid, access: access) && unfetchable.contains(uid)
    }

    public func cacheState(
        for request: ThumbnailRequest, gpuTextureResident: Bool = false
    ) async -> ThumbnailCacheTierState {
        guard ownerLeaseIsCurrent(), readAllowed(request.uid) else {
            return ThumbnailCacheTierState(
                knownInTimeline: true,
                diskThumbnail: false,
                ramDecoded: false,
                gpuTexture: gpuTextureResident
            )
        }
        let cache = self.cache
        let generation = cache.captureWriterGeneration()
        let diskThumbnail = await decodeExecutor.perform(priority: .idleLibraryCrawl) {
            cache.hasUsableDiskData(request.uid)
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
            return ThumbnailCacheTierState(
                knownInTimeline: true,
                diskThumbnail: false,
                ramDecoded: false,
                gpuTexture: gpuTextureResident
            )
        }
        diskPresence.set(request.uid, present: diskThumbnail)
        return ThumbnailCacheTierState(
            knownInTimeline: true,
            diskThumbnail: diskThumbnail,
            ramDecoded: decoded.contains(request.uid),
            gpuTexture: gpuTextureResident
        )
    }

    /// Returns true when this UID is queued already or was queued now. The worker validates encrypted disk
    /// presence away from this actor before crossing the network boundary; admission itself must stay O(1),
    /// because a first-time cache validation performs a real file read and AES-GCM open.
    @discardableResult
    public func requestPriority(_ uid: PhotoUID, priority requestedPriority: ThumbnailPriority = .visibleNow) -> Bool {
        // Local pending photos load through visible and warm demand only, never through the network queue.
        guard !uid.isLocalPending, readAllowed(uid) else { return false }
        if requestedPriority != .idleLibraryCrawl { lastDemand.set(clock()) }
        if let index = priorityReservations.firstIndex(where: { $0.uid == uid }) {
            if requestedPriority < priorityReservations[index].priority {
                priorityReservations[index].priority = requestedPriority
                diagnostics.increment("thumb.priorityUpgrade")
            }
            return true
        }
        if let existing = priorityByUID[uid] {
            if requestedPriority < existing {
                priorityByUID[uid] = requestedPriority
                diagnostics.increment("thumb.priorityUpgrade")
            }
            return true
        }
        priority.append(uid)
        priorityByUID[uid] = requestedPriority
        trimPriorityQueueIfNeeded()
        endWindowPermitWaits()
        startWorkers()
        return true
    }

    /// Hands withheld photos back to the crawl. The next request issues a fresh authorization; a photo that left
    /// the library is then refused, or the feed no longer authorizes it and the crawl skips it.
    private func requeueWithheld(_ uids: [PhotoUID]) {
        // Without a crawl, nothing would take them; the next request for the photo loads it. The apps keep the crawl on.
        guard prefetchEnabled else { return }
        for uid in uids where !uid.isLocalPending && readAllowed(uid) && !withheldRetry.contains(uid) {
            let attempts = withheldRequeues[uid, default: 0]
            guard attempts < Self.maxWithheldRequeues else {
                if attempts == Self.maxWithheldRequeues {
                    withheldRequeues[uid] = attempts + 1
                    recordError(
                        "thumbnail withheld for \(Self.key(uid)) \(attempts + 1) times; the next crawl or a visible request loads it"
                    )
                }
                continue
            }
            withheldRequeues[uid] = attempts + 1
            withheldRetry.append(uid)
        }
    }

    /// Replace the queued network demand owned by the live grid viewport.
    ///
    /// The list is ordered in viewport priority (the newly exposed edge first). Replacing, rather than merely
    /// appending, is important during a fast scroll: old `.visibleNow` entries must not remain tied with the new
    /// viewport, and an off-screen scroll-ahead corridor must not keep consuming admissions after its cells have
    /// been skipped. Requests already inside the SDK cannot be recalled; this only removes work that has not
    /// crossed the network admission boundary.
    @discardableResult
    public func replaceVisiblePriorityDemand(_ orderedUIDs: [PhotoUID]) -> Int {
        lastDemand.set(clock())
        let orderedUIDs = orderedUIDs.filter { !$0.isLocalPending }
        visiblePriorityDemand = orderedUIDs
        guard !sourceReconciliationInFlight else { return 0 }
        return applyVisiblePriorityDemand(orderedUIDs)
    }

    private func applyVisiblePriorityDemand(_ orderedUIDs: [PhotoUID]) -> Int {
        removeQueuedPriorities([.visibleNow, .nearViewportScrollAhead])

        var seen = Set<PhotoUID>()
        var queued = 0
        for uid in orderedUIDs where seen.insert(uid).inserted {
            if requestPriority(uid, priority: .visibleNow) { queued += 1 }
        }
        return queued
    }

    public nonisolated func hasRecentVisibleDemand(within: TimeInterval = 2.0) -> Bool {
        guard let last = lastDemand.get() else { return false }
        return clock().timeIntervalSince(last) < within
    }

    /// Records that a viewport is live without enqueuing or decoding anything - a single lock-guarded clock
    /// write, `nonisolated` so it never queues on the serial actor. The per-frame warm path calls this the
    /// instant the first visible cells are known, so the background crawl's `recentDemand` gate (`takeBatch` /
    /// the end-of-list coverage re-scan) backs its filesystem scanning off immediately and yields the actor to
    /// the visible decode - instead of the crawl only learning of demand once `warmDecoded` itself reaches the
    /// actor, the very call the crawl is starving on a cold start.
    public nonisolated func noteVisibleDemand() {
        lastDemand.set(clock())
    }

    public func hasPendingThumbnailWork() -> Bool {
        guard prefetchEnabled else { return false }
        return !priority.isEmpty || sequentialIndex < sequential.count
    }

    /// Waits for an already-started thumbnail crawl, including authenticated disk probes and its final
    /// downloads. A drained queue alone is not completion: workers may still be writing the last batch.
    /// Cancelling the waiter leaves the feed running, so account teardown can join the caller before the feed.
    public func waitForPrefetchToFinish() async throws {
        while prefetchEnabled, ownerLeaseIsCurrent(),
            workersRunning || diskProbeBatchesInFlight > 0 || downloadInFlight > 0 || timedOutLoaders > 0
        {
            try await Task.sleep(for: .milliseconds(250))
        }
        try Task.checkCancellation()
    }

    /// True only while the grid needs the backend: queued visible-priority work or live viewport demand.
    /// Unlike `hasPendingThumbnailWork()`, this excludes the whole-library
    /// sequential fill: lower-priority background work (the Map's GPS crawl) yields on this, so it backs
    /// off while the user scrolls but is not parked until a full-library thumbnail crawl finishes.
    public func hasVisibleThumbnailPressure() -> Bool {
        guard prefetchEnabled else { return false }
        return !priority.isEmpty || hasRecentVisibleDemand()
    }

    public func warmDecoded(
        _ requests: [ThumbnailRequest],
        priority requestedPriority: ThumbnailPriority,
        limit: Int
    ) async -> WarmDecodedResult {
        await warmDecodedImpl(
            requests,
            priority: requestedPriority,
            limit: limit
        )
    }

    /// Publishes the moving viewport through a latest-value mailbox. This is deliberately `nonisolated`: a
    /// scrolling host must never queue hundreds of obsolete actor messages while disk maintenance is yielding.
    /// Network admission remains a separate stable-viewport operation.
    public nonisolated func submitVisibleDiskDecodeDemand(
        _ requests: [ThumbnailRequest]
    ) {
        lastDemand.set(clock())
        // Keep raw viewport intent. Authorization is an execution fence, not an acknowledgement that
        // these tiles were loaded: the first viewport can arrive before its source scope is admitted.
        guard visibleDiskDemandInbox.submit(requests: requests) else { return }
        Task { await drainVisibleDiskDemandInbox() }
    }

    private func replayVisibleDiskDecodeDemand() {
        guard ownerLeaseIsCurrent(), visibleDiskDemandInbox.replay() else { return }
        Task { drainVisibleDiskDemandInbox() }
    }

    private func drainVisibleDiskDemandInbox() {
        while let submission = visibleDiskDemandInbox.takeLatestOrFinish() {
            applyVisibleDiskDecodeDemand(
                submission.requests, generation: submission.generation, isReplay: submission.isReplay)
        }
    }

    /// A replay re-applies only Proton demand: local loads wake their hosts, which submit fresh demand, so a
    /// suspended grid's local viewport never restarts from a replay.
    private func applyVisibleDiskDecodeDemand(
        _ requests: [ThumbnailRequest],
        generation: UInt64,
        isReplay: Bool = false
    ) {
        guard !sourceReconciliationInFlight, ownerLeaseIsCurrent() else {
            // The completion replay skips local demand; the host's next identical viewport must get through.
            if !isReplay { visibleDiskDemandInbox.invalidate() }
            return
        }
        var seen = Set<PhotoUID>()
        var localDemand: [(uid: PhotoUID, pixels: Int)] = []
        var deniedLocal: [PhotoUID: Int] = [:]
        let jobs = requests.compactMap { request -> LatestVisibleDecodeDemand.Job? in
            guard readAllowed(request.uid) else {
                if request.uid.isLocalPending { deniedLocal[request.uid] = Int(visibleDecodePixels(for: request)) }
                return nil
            }
            guard seen.insert(request.uid).inserted else { return nil }
            let pixels = visibleDecodePixels(for: request)
            guard !decoded.hasAdequateEntry(for: request.uid, requestedPixels: Int(pixels)) else { return nil }
            // Local pending photos never touch the encrypted disk tier or its coverage checkpoint.
            if request.uid.isLocalPending {
                localDemand.append((request.uid, Int(pixels)))
                return nil
            }
            return LatestVisibleDecodeDemand.Job(
                uid: request.uid, maxPixels: pixels, isUpgrade: decoded.contains(request.uid))
        }
        if !isReplay {
            deniedLocalDemand = deniedLocal
            submitLocalDemand(localDemand, replacing: true)
        }
        guard visibleDiskDemand.replace(with: jobs, generation: generation) else {
            return
        }
        diagnostics.emitDebug(
            "ThumbSchedule",
            [
                "action": "replaceDiskDemand",
                "generation": "\(generation)",
                "requested": "\(requests.count)",
                "pending": "\(visibleDiskDemand.pendingCount)",
                "active": "\(visibleDiskDemand.activeCount)",
            ], throttleSeconds: 0.10, throttleKey: "replaceDiskDemand")
        startVisibleDiskWorkersIfNeeded()
    }

    private func startVisibleDiskWorkersIfNeeded() {
        guard !sourceReconciliationInFlight else { return }
        let desired = min(configuration.maxConcurrentDecodes, visibleDiskDemand.pendingCount)
        while visibleDiskWorkerCount < desired {
            visibleDiskWorkerCount += 1
            let workerID = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runVisibleDiskWorker(id: workerID)
            }
            visibleDiskWorkerTasks[workerID] = task
        }
    }

    private func runVisibleDiskWorker(id: UUID) async {
        defer {
            visibleDiskWorkerTasks.removeValue(forKey: id)
            visibleDiskWorkerCount = max(0, visibleDiskWorkerCount - 1)
            startVisibleDiskWorkersIfNeeded()
        }
        while let job = visibleDiskDemand.takeNext() {
            let demandGeneration = visibleDiskDemand.generation
            guard await decodePermits.acquire(priority: .visibleNow) else {
                // `false` means this worker was cancelled before it acquired a lane. The asset was not read,
                // so it must remain pending if it still belongs to the latest viewport generation.
                visibleDiskDemand.returnToPending(job)
                break
            }
            let cache = self.cache
            let generation = cache.captureWriterGeneration()
            let executor = decodeExecutor
            let tile = await executor.perform(priority: .visibleNow) {
                Self.decodeTile(
                    cache: cache,
                    uid: job.uid,
                    maxPixels: job.maxPixels,
                    isUpgrade: job.isUpgrade
                )
            }
            await decodePermits.release()
            guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
                decoded.removeAll()
                visibleDiskDemand.complete(job)
                continue
            }
            guard readAllowed(job.uid) else {
                decoded.remove(job.uid)
                visibleDiskDemand.complete(job)
                continue
            }
            publishVisibleDiskTile(tile, generation: generation)
            if tile.decoded == nil, demandGeneration != visibleDiskDemand.generation {
                // A disk arrival can replay the viewport while this read is still returning its earlier
                // miss. Preserve that retry without ever running two decodes for the same UID at once.
                visibleDiskDemand.returnToPending(job)
            } else {
                visibleDiskDemand.complete(job)
            }
        }
    }

    private func publishVisibleDiskTile(_ tile: DecodedTile, generation: CacheWriterGeneration.Token) {
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(generation) else {
            decoded.removeAll()
            return
        }
        guard readAllowed(tile.uid) else {
            decoded.remove(tile.uid)
            return
        }
        recordSlowDecodeStages(tile)
        diagnostics.increment("thumb.ramDecodeMiss")
        guard tile.diskHadData else {
            diskPresence.set(tile.uid, present: false)
            recordCheckpointMissing([tile.uid], writerGeneration: generation)
            return
        }
        diskPresence.set(tile.uid, present: true)
        diagnostics.increment("thumb.diskCacheHit")
        prefetchDecodeStarted += 1
        diagnostics.recordDecodeStarted(queueDepth: visibleDiskDemand.pendingCount)
        guard let image = tile.decoded else {
            diagnostics.increment("thumb.diskDecodeFailed")
            diagnostics.recordDecodeFailed(queueDepth: visibleDiskDemand.pendingCount)
            recordError("decode failed for \(Self.key(tile.uid))")
            return
        }
        storeDecoded(image, for: tile.uid, decodePixelCap: tile.decodePixelCap)
        notifyHostOfAvailableImageIfVisible()
        if tile.isUpgrade { diagnostics.increment("thumb.decodedUpgrade") }
        prefetchDecodeCompleted += 1
        diagnostics.recordDecodeCompleted(
            durationMs: tile.durationMs,
            queueDepth: visibleDiskDemand.pendingCount
        )
    }

    private func warmDecodedImpl(
        _ requests: [ThumbnailRequest],
        priority requestedPriority: ThumbnailPriority,
        limit: Int
    ) async -> WarmDecodedResult {
        let targets = Array(
            requests.lazy
                .filter { self.readAllowed($0.uid) }
                .prefix(max(0, limit))
        )
        noteDeniedLocalDemand(requests.prefix(max(0, limit)))
        lastDemand.set(clock())
        var alreadyDecoded = 0
        var decodedFromDisk = 0
        var queuedNetwork = 0
        var missing = 0
        let mainThreadDecodeCount = 0
        guard ownerLeaseIsCurrent() else {
            return WarmDecodedResult(
                requested: targets.count,
                alreadyDecoded: 0,
                decodedFromDisk: 0,
                queuedNetwork: 0,
                missing: 0,
                mainThreadDecodeCount: mainThreadDecodeCount
            )
        }
        guard !Task.isCancelled else {
            return WarmDecodedResult(
                requested: targets.count,
                alreadyDecoded: 0,
                decodedFromDisk: 0,
                queuedNetwork: 0,
                missing: 0,
                mainThreadDecodeCount: mainThreadDecodeCount
            )
        }
        var needDecode: [(uid: PhotoUID, pixels: CGFloat, isUpgrade: Bool)] = []
        needDecode.reserveCapacity(targets.count)
        var localDemand: [(uid: PhotoUID, pixels: Int)] = []
        for request in targets {
            // Size-aware skip: "already decoded" only counts when the cached entry's decode cap is adequate
            // for this request (shared `ThumbnailDecodeUpgradePolicy` hysteresis). A materially larger ask
            // re-decodes the same UID sharper, in place - this is what lets a zoomed-in grid level sharpen
            // tiles that were first decoded for a denser level.
            let pixels = effectiveDecodePixels(for: request)
            if decoded.hasAdequateEntry(for: request.uid, requestedPixels: Int(pixels)) {
                diagnostics.increment("thumb.ramDecodedHit")
                alreadyDecoded += 1
            } else if request.uid.isLocalPending {
                localDemand.append((request.uid, Int(pixels)))
            } else {
                needDecode.append((request.uid, pixels, decoded.contains(request.uid)))
            }
        }
        // Device loads may wait for iCloud; they never hold back the Proton decodes of this pass. The visible
        // pass owns the local queue, like the visible disk demand.
        if requestedPriority == .visibleNow || !localDemand.isEmpty {
            submitLocalDemand(localDemand, replacing: requestedPriority == .visibleNow)
            queuedNetwork += localDemand.count
        }
        if !needDecode.isEmpty {
            let cache = self.cache
            let decodeGeneration = cache.captureWriterGeneration()
            let decodePermits = self.decodePermits
            let decodeExecutor = self.decodeExecutor
            let lanes = max(1, min(needDecode.count, configuration.maxConcurrentDecodes))
            await withTaskGroup(of: DecodedTile?.self) { group in
                var iterator = needDecode.makeIterator()
                func addNext() {
                    guard !Task.isCancelled else { return }
                    guard let (uid, maxPixels, isUpgrade) = iterator.next() else { return }
                    group.addTask {
                        guard await decodePermits.acquire(priority: requestedPriority) else { return nil }
                        guard !Task.isCancelled else {
                            await decodePermits.release()
                            return nil
                        }
                        let tile = await decodeExecutor.perform(priority: requestedPriority) {
                            Self.decodeTile(cache: cache, uid: uid, maxPixels: maxPixels, isUpgrade: isUpgrade)
                        }
                        await decodePermits.release()
                        return Task.isCancelled ? nil : tile
                    }
                }
                for _ in 0..<lanes { addNext() }
                for await tile in group {
                    if Task.isCancelled || !ownerLeaseIsCurrent()
                        || !cache.isCurrentWriterGeneration(decodeGeneration)
                    {
                        group.cancelAll()
                        continue
                    }
                    if let tile {
                        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(decodeGeneration),
                            readAllowed(tile.uid)
                        else {
                            group.cancelAll()
                            continue
                        }
                        recordSlowDecodeStages(tile)
                        diagnostics.increment("thumb.ramDecodeMiss")
                        if tile.diskHadData {
                            diskPresence.set(tile.uid, present: true)
                            diagnostics.increment("thumb.diskCacheHit")
                            prefetchDecodeStarted += 1
                            diagnostics.recordDecodeStarted(queueDepth: 0)
                            if let image = tile.decoded {
                                // Publish each completed decode immediately. Waiting for the slowest member of
                                // a large visible batch made every already-finished tile remain a placeholder,
                                // which surfaced most often on macOS because its decode policy uses more lanes.
                                storeDecoded(image, for: tile.uid, decodePixelCap: tile.decodePixelCap)
                                notifyHostOfAvailableImageIfVisible()
                                if tile.isUpgrade { diagnostics.increment("thumb.decodedUpgrade") }
                                prefetchDecodeCompleted += 1
                                diagnostics.recordDecodeCompleted(durationMs: tile.durationMs, queueDepth: 0)
                                decodedFromDisk += 1
                            } else {
                                missing += 1
                                diagnostics.increment("thumb.diskDecodeFailed")
                                diagnostics.recordDecodeFailed(queueDepth: 0)
                                recordError("decode failed for \(Self.key(tile.uid))")
                            }
                        } else {
                            // Admission is O(1); the worker revalidates encrypted disk presence off actor
                            // before it crosses the network boundary, covering a byte arrival in this race.
                            requestPriority(tile.uid, priority: requestedPriority)
                            queuedNetwork += 1
                        }
                    }
                    addNext()
                }
            }
        }
        return WarmDecodedResult(
            requested: targets.count,
            alreadyDecoded: alreadyDecoded,
            decodedFromDisk: decodedFromDisk,
            queuedNetwork: queuedNetwork,
            missing: missing,
            mainThreadDecodeCount: mainThreadDecodeCount
        )
    }

    /// Decode or enqueue the current on-screen viewport at the highest thumbnail priority.
    ///
    /// The priority is deliberately not configurable here. Platform grids report visibility; they do not
    /// decide how visible work competes with zoom targets, scroll-ahead preparation, or the library crawl.
    public func warmVisibleDecoded(
        _ requests: [ThumbnailRequest],
        limit: Int
    ) async -> WarmDecodedResult {
        await warmDecoded(requests, priority: .visibleNow, limit: limit)
    }

    public func warmDecoded(_ uids: [PhotoUID], limit: Int = 160) async -> WarmDecodedResult {
        await warmDecoded(
            uids.map { ThumbnailRequest(uid: $0, pixelSize: Int(configuration.targetPixels)) },
            priority: .zoomAnchorAndFocusRow,
            limit: limit
        )
    }

    public func decoded(for uid: PhotoUID, access: VisibleThumbnailAccess? = nil) async -> DecodedThumbnail? {
        guard ownerLeaseIsCurrent() else {
            decoded.removeAll()
            return nil
        }
        guard readAllowed(uid, access: access) else { return nil }
        // Local photos never touch the disk tier or share a Proton flight; see `loadLocalDirect`.
        if uid.isLocalPending { return await loadLocalDirect(uid) }
        if let image = await cachedDecoded(for: uid, access: access) { return image }
        // Visible tiles re-request on every appearance; once the backend has said "no thumbnail"
        // for this crawl, don't burn a network round-trip per visibility.
        if unfetchable.contains(uid) {
            diagnostics.increment("thumb.unfetchableShortCircuit")
            return nil
        }
        let key = DirectDecodeKey(uid: uid, accessID: access?.id)
        if let flight = directDecodeFlights[key] {
            return await flight.task.value
        }

        nextDirectDecodeFlightID &+= 1
        let flightID = nextDirectDecodeFlightID
        let flight: Task<DecodedThumbnail?, Never> = Task { [weak self] in
            guard let self else { return nil }
            return await self.loadDirectDecoded(for: uid, access: access)
        }
        directDecodeFlights[key] = DirectDecodeFlight(id: flightID, task: flight)
        let result = await withTaskCancellationHandler {
            await flight.value
        } onCancel: {
            // A foreground capability belongs to this caller; ordinary shared flights keep their existing lifetime.
            if let access {
                access.end()
                flight.cancel()
            }
        }
        if directDecodeFlights[key]?.id == flightID {
            directDecodeFlights.removeValue(forKey: key)
        }
        return result
    }

    /// Loads a local photo for a direct caller (the viewer's first frame). It runs in the caller's task, so the
    /// caller's cancellation stops a download it started.
    private func loadLocalDirect(_ uid: PhotoUID) async -> DecodedThumbnail? {
        let pixels = Int(configuration.targetPixels)
        let generation = localGeneration
        // Every await can change the running load: a cancelled one may finish and a queued viewport
        // request may start a replacement. Re-check after each wait, join the current load and pin it,
        // and stop when the feed stops. Bounded, so a load that keeps being replaced cannot spin.
        for _ in 0..<4 {
            guard decoded.image(for: uid) == nil, !Task.isCancelled, localGeneration == generation else { break }
            if let load = localLoads[uid] {
                // Joining does not pin: if a suspension cancels this load, the next pass starts one this
                // caller owns, and the caller's own cancellation stops it.
                await load.task.value
            } else if localLoads.count < Self.maxLocalLoads, shouldLoadLocal(uid, pixels: pixels),
                let localLoader
            {
                // Direct callers share the load limit, and their own cancellation (a viewer paging on)
                // stops the download.
                let load = startLocalLoad(uid, pixels: pixels, loader: localLoader, pinned: true)
                await withTaskCancellationHandler {
                    await load.value
                } onCancel: {
                    load.cancel()
                }
            } else {
                break
            }
        }
        return decoded.image(for: uid)
    }

    private func loadDirectDecoded(for uid: PhotoUID, access: VisibleThumbnailAccess?) async -> DecodedThumbnail? {
        guard readAllowed(uid, access: access) else { return nil }
        let box = ByteBox()
        let cache = self.cache
        let writerGeneration = access?.cacheGeneration ?? cache.captureWriterGeneration()
        guard cache.isCurrentWriterGeneration(writerGeneration) else { return nil }
        diagnostics.recordNetworkRequestDuringPinch()
        if batchesInFlight.values.contains(where: { $0.contains(uid) }) {
            diagnostics.increment("thumb.directLoadOverlapsBatch")
        }
        let result: ThumbnailBatchLoadResult
        if let priorityLoader = loader as? any PriorityThumbnailBatchLoader {
            result = await priorityLoader.loadThumbnails(for: [uid], priority: .visibleNow) { loadedUID, data in
                if loadedUID == uid { box.set(data) }
            }
        } else {
            result = await loader.loadThumbnails(for: [uid]) { loadedUID, data in
                if loadedUID == uid { box.set(data) }
            }
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(writerGeneration) else {
            decoded.removeAll()
            return nil
        }
        guard readAllowed(uid, access: access) else { return nil }
        guard let data = box.value else {
            if let reason = result.itemErrors[uid] {
                scheduleRefusalLapseWake(unfetchable.insert(uid))
                recordError("thumbnail refused for \(Self.key(uid)): \(reason)")
            } else if result.withheldUIDs.contains(uid) {
                recordError("thumbnail withheld for \(Self.key(uid)) after an authorization change")
            } else if let reason = result.batchError {
                recordError("thumbnail fetch failed for \(Self.key(uid)): \(reason)")
            }
            return nil
        }
        let maxPixels = configuration.targetPixels
        let (image, stored): (DecodedThumbnail?, ThumbnailCacheStoreResult) = await decodeExecutor.perform(
            priority: .visibleNow
        ) {
            let stored: ThumbnailCacheStoreResult
            if let access {
                stored = cache.storeToDisk(
                    data, for: uid, ifCurrent: writerGeneration,
                    authorizing: { [self] in cacheReadAuthorized(uid, access: access) })
            } else {
                stored = cache.storeToDisk(data, for: uid, ifCurrent: writerGeneration)
            }
            guard stored == .stored || stored == .storagePaused else { return (nil, stored) }
            return (ThumbnailImageDecoder.downsample(data, maxPixelSize: maxPixels), stored)
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(writerGeneration) else {
            decoded.removeAll()
            return nil
        }
        guard readAllowed(uid, access: access) else { return nil }
        if stored == .stored { diskPresence.set(uid, present: true) }
        cacheArrivalWake.call()
        guard let image else {
            diagnostics.increment("thumb.diskDecodeFailed")
            recordError("decode failed for \(Self.key(uid))")
            return nil
        }
        return storeDecoded(image, for: uid, decodePixelCap: Int(configuration.targetPixels), access: access)
    }

    public func startPrefetch(_ uids: [PhotoUID]) async {
        refusalWakesAllowed = true
        if let lastSelectedScope, let lastAnalysisScope, let lastRetentionScope {
            await startPrefetch(
                Self.crawlOrder(
                    selected: lastSelectedScope,
                    analysis: lastAnalysisScope,
                    retention: lastRetentionScope
                ),
                reporting: lastSelectedScope.uids,
                requiringSourceRevision: lastAnalysisScope.revision
            )
        } else {
            noteMembership(Set(uids))
            await startPrefetch(uids, reporting: Set(uids), requiringSourceRevision: nil)
        }
    }

    /// Records the photos that joined since the previous membership. The first membership only sets the baseline.
    private func noteMembership(_ uids: Set<PhotoUID>) {
        if let knownMembership {
            unfetchable.noteJoined(uids.subtracting(knownMembership).filter { !$0.isLocalPending })
        }
        knownMembership = uids
    }

    /// False after a stop that drops visible demand, until the feed starts again: a stopped feed, also a load that
    /// ends after the stop, wakes no host. A refusal still lapses; the next visible request asks again.
    private var refusalWakesAllowed = true

    private func scheduleRefusalLapseWake(_ due: Date?) {
        guard let due, refusalWakesAllowed else { return }
        if let scheduled = refusalLapseWake {
            guard due < scheduled.due else { return }
            scheduled.task.cancel()
        }
        let delay = max(0, due.timeIntervalSince(clock()))
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.wakeHostsForLapsedRefusal(due)
        }
        refusalLapseWake = (due, task)
    }

    /// Visible grids ask for the lapsed photo again on this wake. Each lapse wakes at most once, and
    /// `maxRecentJoinRefusalLapses` bounds the lapses of one photo.
    private func wakeHostsForLapsedRefusal(_ due: Date) {
        guard refusalLapseWake?.due == due else { return }
        refusalLapseWake = nil
        wakeHostsForLocalArrival()
        // One wake covers every lapse that is due by now, also after a late resume.
        scheduleRefusalLapseWake(unfetchable.nextLapse(after: max(due, clock())))
    }

    /// Background crawl order: the main library grid first, then thumbnails of additional sources, then the
    /// burst members, which only a series filmstrip shows, and last the photos in Recently Deleted, so that
    /// route also opens offline. Visible demand still preempts the whole crawl.
    private static func crawlOrder(
        selected: SelectedDerivedDataScope,
        analysis: AnalysisDerivedDataScope,
        retention: ThumbnailRetentionDerivedDataScope
    ) -> [PhotoUID] {
        var orderedUIDs = selected.orderedUIDs
        var seen = Set(orderedUIDs)
        orderedUIDs.append(contentsOf: analysis.orderedUIDs.filter { seen.insert($0).inserted })
        orderedUIDs.append(contentsOf: retention.orderedUIDs.filter { seen.insert($0).inserted })
        orderedUIDs.append(contentsOf: retention.authorizationOnlyOrder.filter { seen.insert($0).inserted })
        return orderedUIDs
    }

    private func startPrefetch(
        _ uids: [PhotoUID],
        reporting reportingUIDs: Set<PhotoUID>,
        requiringSourceRevision requiredSourceRevision: UInt64?
    ) async {
        guard prefetchEnabled, ownerLeaseIsCurrent() else { return }
        if let requiredSourceRevision {
            guard lastAnalysisScope?.revision == requiredSourceRevision else { return }
        }
        let uids = uids.filter { readAllowed($0) }
        prefetchReportingUIDs = reportingUIDs
        flushCheckpointUpdates()
        restorePriorityReservationsForRestart()
        prefetchGeneration &+= 1
        let generation = prefetchGeneration
        cancelCrawlWake()
        let activeWorker = workerTask
        workerTasks.forEach { $0.cancel() }
        workerTasks.removeAll(keepingCapacity: false)
        activeWorker?.cancel()
        if let activeWorker {
            retiredWorkerTasks.append(activeWorker)
        }
        workerTask = nil
        workersRunning = false
        sequential = uids
        sequentialIndex = 0

        // Coverage-log parsing and cache-directory enumeration are local I/O. Keep them off the
        // serial feed actor so first-visible disk decrypt/decode can run immediately after login.
        let coverageStore = self.coverageStore
        let coverageKey = coverageCheckpointKey
        let cache = self.cache
        let cacheGeneration = cache.captureWriterGeneration()
        let bootstrap = await Task.detached(priority: .utility) {
            Set(coverageStore?.loadPresent(uids, for: coverageKey) ?? [])
        }.value
        guard generation == prefetchGeneration, prefetchEnabled else { return }
        if let requiredSourceRevision {
            guard lastAnalysisScope?.revision == requiredSourceRevision else { return }
        }
        guard cache.isCurrentWriterGeneration(cacheGeneration) else { return }

        if diskPresenceGeneration != cacheGeneration {
            diskPresence.invalidate()
            diskPresenceGeneration = cacheGeneration
        }

        checkpointHints = bootstrap
        checkpointPresent.removeAll(keepingCapacity: true)
        // A persisted checkpoint is advisory only. Every UID starts at zero and crosses the bounded utility
        // probe before the crawl can skip it, so a removed or corrupt blob cannot hide behind a stale checkpoint.
        // Only the first complete crawl of this feed authenticates blobs that the process already proved.
        startupAuthenticationPending = !uids.isEmpty && !authenticatedCrawlCompleted
        sequentialIndex = 0
        diskPresence.beginTracking(uids, reporting: reportingUIDs, knownPresent: [])
        unfetchable.removeAll()  // a fresh crawl retries backend-refused items exactly once
        withheldRetry.removeAll()
        withheldRequeues.removeAll()
        lastRepassPercent = -1.0
        coverageScanCursor = 0
        coverageSettled = false
        coverageRefreshInFlight = false
        coverageRefreshStarts = 0
        coverageFullScans = 0
        startWorkers()
    }

    public func stopPrefetch() {
        stopPrefetch(preservingVisibleDemand: false)
    }

    private func stopPrefetch(preservingVisibleDemand: Bool) {
        if !preservingVisibleDemand {
            visibleAccessLifetime.invalidate()
            visibleDiskDemandInbox.cancel()
            visiblePriorityDemand = nil
            // A stopped feed wakes no host for a lapsed refusal, also not for a load that ends after the stop.
            refusalWakesAllowed = false
            refusalLapseWake?.task.cancel()
            refusalLapseWake = nil
        }
        flushCheckpointUpdates()
        prefetchGeneration &+= 1
        cancelCrawlWake()
        let activeWorker = workerTask
        workerTasks.forEach { $0.cancel() }
        workerTasks.removeAll(keepingCapacity: false)
        activeWorker?.cancel()
        if let activeWorker {
            retiredWorkerTasks.append(activeWorker)
        }
        workerTask = nil
        workersRunning = false
        priority.removeAll()
        priorityByUID.removeAll()
        priorityReservations.removeAll(keepingCapacity: false)
        batchesInFlight.removeAll(keepingCapacity: false)
        sequential.removeAll()
        withheldRetry.removeAll()
        withheldRequeues.removeAll()
        startupAuthenticationPending = false
        for flight in directDecodeFlights.values {
            flight.task.cancel()
            retiredDirectDecodeTasks.append(flight.task)
        }
        directDecodeFlights.removeAll(keepingCapacity: false)
        visibleDiskDemand.cancelAll()
        for task in visibleDiskWorkerTasks.values {
            task.cancel()
            retiredVisibleDiskWorkerTasks.append(task)
        }
        localGeneration &+= 1
        // A replay skips local demand, so the host's next identical viewport must restart these loads.
        if !localLoads.isEmpty || !localDemand.isEmpty { visibleDiskDemandInbox.invalidate() }
        localDemand.removeAll()
        deniedLocalDemand.removeAll()
        for load in localLoads.values {
            load.task.cancel()
            retiredVisibleDiskWorkerTasks.append(load.task)
        }
        localLoads.removeAll()
        localRetryTask?.task.cancel()
        localRetryTask = nil
        localRetryAt.removeAll()
        localFailedAttempts.removeAll()
        visibleDiskWorkerTasks.removeAll(keepingCapacity: false)
    }

    /// Stops and joins every worker owned by this feed instance. Account retry and sign-out use this
    /// boundary before releasing the backend; destructive cache clear remains generation-fenced and non-blocking.
    public func stopPrefetchAndWait() async {
        await stopPrefetchAndWait(preservingVisibleDemand: false)
    }

    private func stopPrefetchAndWait(preservingVisibleDemand: Bool) async {
        stopPrefetch(preservingVisibleDemand: preservingVisibleDemand)
        while true {
            let retiredWorkers = retiredWorkerTasks
            retiredWorkerTasks.removeAll(keepingCapacity: false)
            for task in retiredWorkers {
                await task.value
            }

            // A worker registers a cancellation-ignoring SDK loader after its bounded timeout.
            // Read this collection after the workers finish so no late native owner escapes.
            let lateLoaders = Array(timedOutLoaderTasks.values)
            for task in lateLoaders {
                await task.value
            }

            let directLoads = retiredDirectDecodeTasks
            retiredDirectDecodeTasks.removeAll(keepingCapacity: false)
            for task in directLoads {
                _ = await task.value
            }

            let visibleWorkers = retiredVisibleDiskWorkerTasks
            retiredVisibleDiskWorkerTasks.removeAll(keepingCapacity: false)
            for task in visibleWorkers {
                await task.value
            }

            guard retiredWorkerTasks.isEmpty,
                timedOutLoaderTasks.isEmpty,
                retiredDirectDecodeTasks.isEmpty,
                retiredVisibleDiskWorkerTasks.isEmpty,
                visibleDiskWorkerTasks.isEmpty
            else { continue }
            break
        }
    }

    /// Clears the encrypted thumbnail tier and its coverage state as one feed operation, then restarts the
    /// current library crawl. Stopping first prevents an old worker or checkpoint from repopulating stale
    /// coverage after the cache directory has been removed.
    public func clearCacheAndRestartPrefetch() async {
        let current = sequential
        let shouldRestart = prefetchEnabled && !current.isEmpty
        stopPrefetch()
        await cache.clear()
        checkpointPresent.removeAll()
        checkpointHints.removeAll()
        diskPresence.invalidate()
        authenticatedCrawlCompleted = false
        if shouldRestart { await startPrefetch(current) }
    }

    /// Binds this feed and its encrypted cache to one graph lifetime.
    @discardableResult
    public func bindDerivedDataEpoch(_ epoch: LibrarySourceEpoch) -> Bool {
        guard sourceEpoch == nil || sourceEpoch == epoch else { return false }
        guard cache.bindDerivedDataEpoch(epoch, sessionLease: ownerSessionLease) else { return false }
        thumbnailReadAuthorization.requireScope()
        if sourceEpoch == nil { highestSourceReconciliationRevision = nil }
        sourceEpoch = epoch
        return true
    }

    /// Replaces every source-aware feed projection from one atomic graph change.
    ///
    /// The retention scope controls encrypted disk bytes and authorizes thumbnail reads, including explicit demand
    /// from shared album grids and burst filmstrips. The selected scope controls main-library coverage.
    /// Background crawling does not decode into the grid LRU; only a foreground request does that.
    /// All scopes must come from the same graph revision.
    @discardableResult
    public func reconcile(
        selected selectedScope: SelectedDerivedDataScope,
        analysis analysisScope: AnalysisDerivedDataScope,
        retention retentionScope: ThumbnailRetentionDerivedDataScope
    ) async -> MediaCacheReconciliationResult {
        guard selectedScope.epoch == analysisScope.epoch,
            selectedScope.epoch == retentionScope.epoch,
            selectedScope.revision == analysisScope.revision,
            selectedScope.revision == retentionScope.revision,
            let sourceEpoch,
            sourceEpoch == selectedScope.epoch
        else { return self.sourceEpoch == nil ? .unbound : .staleScope }
        if let lastSelectedScope, let lastAnalysisScope, let lastRetentionScope {
            let isExactRetry =
                selectedScope == lastSelectedScope
                && analysisScope == lastAnalysisScope
                && retentionScope == lastRetentionScope
            guard isExactRetry || selectedScope.revision > lastSelectedScope.revision else {
                return .staleScope
            }
        }
        if let highestSourceReconciliationRevision {
            guard selectedScope.revision >= highestSourceReconciliationRevision else { return .staleScope }
        }
        refusalWakesAllowed = true
        highestSourceReconciliationRevision = selectedScope.revision

        // Authorization changes immediately even when another reconciliation owns the slow worker/cache
        // boundary. That owner consumes only the newest queued revision, so an older continuation can never
        // overwrite a newer feed state after one of the awaits below.
        thumbnailReadAuthorization.apply(retentionScope)
        noteMembership(retentionScope.uids)
        // Handed-over photos the scope now covers need no exception any more.
        adoptedAuthorization.subtract(retentionScope.uids)
        let incomingRequest = SourceReconciliationRequest(
            selectedScope: selectedScope,
            analysisScope: analysisScope,
            retentionScope: retentionScope
        )
        guard !sourceReconciliationInFlight else {
            if pendingSourceReconciliation.map({ $0.selectedScope.revision <= selectedScope.revision }) ?? true {
                pendingSourceReconciliation = incomingRequest
            }
            return await withCheckedContinuation { continuation in
                sourceReconciliationWaiters.append(
                    SourceReconciliationWaiter(
                        revision: selectedScope.revision,
                        continuation: continuation
                    )
                )
            }
        }

        sourceReconciliationInFlight = true
        var resumeVisibleDemand = false
        defer {
            sourceReconciliationInFlight = false
            if resumeVisibleDemand, ownerLeaseIsCurrent() {
                replayVisibleDiskDecodeDemand()
                if let visiblePriorityDemand {
                    _ = applyVisiblePriorityDemand(visiblePriorityDemand)
                }
                // Both native hosts already re-warm on this Core wake. In particular, UIKit's awaited
                // warm pass may have completed while authorization was still empty or workers were joined.
                imagesAvailableWake.call()
            }
        }
        let incomingRevision = selectedScope.revision
        var request = incomingRequest

        while true {
            // Join the previous crawl before removing its coverage checkpoint. No retired worker can recreate
            // old cache or checkpoint state after cleanup.
            await stopPrefetchAndWait(preservingVisibleDemand: true)

            if let pending = pendingSourceReconciliation,
                pending.selectedScope.revision >= request.selectedScope.revision
            {
                request = pending
                pendingSourceReconciliation = nil
            }

            // Reconciliation can unlink many encrypted blobs after a source is removed. Keep that bounded local
            // maintenance off this actor so visible thumbnail requests remain responsive while it completes.
            let cache = self.cache
            let retentionScope = request.retentionScope
            let cacheResult = await Task.detached(priority: .utility) {
                cache.reconcile(with: retentionScope)
            }.value

            if let pending = pendingSourceReconciliation,
                pending.selectedScope.revision > request.selectedScope.revision
            {
                request = pending
                pendingSourceReconciliation = nil
                continue
            }
            if pendingSourceReconciliation?.selectedScope.revision == request.selectedScope.revision {
                pendingSourceReconciliation = nil
            }
            switch cacheResult {
            case .unbound, .staleScope:
                resumeSourceReconciliationWaiters(
                    processedRevision: request.selectedScope.revision,
                    result: cacheResult
                )
                return incomingRevision == request.selectedScope.revision ? cacheResult : .staleScope
            case .deferred, .reconciled, .ioFailure:
                break
            }

            lastSelectedScope = request.selectedScope
            lastAnalysisScope = request.analysisScope
            lastRetentionScope = request.retentionScope

            // Join first, then remove only plaintext which lost thumbnail access. The source and cache
            // fences already reject a cancellation-ignoring loader, so retained tiles stay immediately usable.
            decoded.retainOnly(
                request.retentionScope.uids.union(localAuthorization.snapshot).union(adoptedAuthorization.snapshot))
            checkpointPresent.removeAll(keepingCapacity: true)
            checkpointHints.removeAll(keepingCapacity: true)
            pendingCheckpointUpdates.removeAll(keepingCapacity: true)
            unfetchable.removeAll()
            withheldRetry.removeAll()
            withheldRequeues.removeAll()
            visibleDiskDemand.cancelAll()
            diskProbeBatchesInFlight = 0
            sequential = []
            sequentialIndex = 0
            resetGenerationStatistics()

            guard lastSelectedScope?.revision == request.selectedScope.revision else {
                if let pendingSourceReconciliation {
                    request = pendingSourceReconciliation
                    self.pendingSourceReconciliation = nil
                    continue
                }
                resumeSourceReconciliationWaiters(
                    processedRevision: request.selectedScope.revision,
                    result: .staleScope
                )
                return .staleScope
            }

            if prefetchEnabled, !request.analysisScope.orderedUIDs.isEmpty {
                await startPrefetch(
                    Self.crawlOrder(
                        selected: request.selectedScope,
                        analysis: request.analysisScope,
                        retention: request.retentionScope
                    ),
                    reporting: request.selectedScope.uids,
                    requiringSourceRevision: request.analysisScope.revision
                )
            }

            if let pending = pendingSourceReconciliation,
                pending.selectedScope.revision > request.selectedScope.revision
            {
                request = pending
                pendingSourceReconciliation = nil
                continue
            }
            resumeSourceReconciliationWaiters(
                processedRevision: request.selectedScope.revision,
                result: cacheResult
            )
            resumeVisibleDemand = true
            return incomingRevision == request.selectedScope.revision ? cacheResult : .staleScope
        }
    }

    private func resumeSourceReconciliationWaiters(
        processedRevision: UInt64,
        result: MediaCacheReconciliationResult
    ) {
        let waiters = sourceReconciliationWaiters
        sourceReconciliationWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.continuation.resume(
                returning: waiter.revision == processedRevision ? result : .staleScope
            )
        }
    }

    private func resetGenerationStatistics() {
        prefetchCompleted = 0
        prefetchFailed = 0
        prefetchFailedTimeout = 0
        prefetchFailedBatchError = 0
        prefetchFailedItemError = 0
        prefetchFailedUnreported = 0
        prefetchFailedWithheld = 0
        prefetchDiskHit = 0
        prefetchDownloadStarted = 0
        prefetchDownloadCompleted = 0
        prefetchDecodeStarted = 0
        prefetchDecodeCompleted = 0
        skippedUnfetchable = 0
        lastErrors.removeAll(keepingCapacity: true)
    }

    private func isReportedForPrefetch(_ uid: PhotoUID) -> Bool {
        prefetchReportingUIDs?.contains(uid) ?? true
    }

    private func reportedCount(in uids: [PhotoUID]) -> Int {
        guard let prefetchReportingUIDs else { return uids.count }
        return uids.reduce(into: 0) { count, uid in
            if prefetchReportingUIDs.contains(uid) { count += 1 }
        }
    }

    public func setPrefetchEnabled(_ enabled: Bool) {
        prefetchEnabled = enabled
        if !enabled { stopPrefetch() }
    }

    public func pausePrefetch() {
        prefetchPaused = true
    }

    public func resumePrefetch() {
        prefetchPaused = false
        startWorkers()
    }

    /// One platform grid host reports only its own gesture state. Several windows can drive the same shared
    /// feed at once; the feed stays interacting while any owner is active, and a host that stops, switches
    /// feeds, or goes away removes only its own contribution.
    public nonisolated func setUserInteractionActive(_ active: Bool, owner: ThumbnailInteractionOwner) {
        interactionState.set(active, owner: owner)
    }

    /// True only while at least one platform host reports an active gesture or scroll deceleration. A visible
    /// grid and queued/missing thumbnails do not count: those may remain pending indefinitely and
    /// must not starve background indexing after the user becomes idle.
    public nonisolated func hasActiveUserInteraction() -> Bool {
        interactionState.hasActiveOwners()
    }

    /// Number of hosts currently reporting an active gesture (diagnostics and tests).
    public nonisolated func activeUserInteractionOwnerCount() -> Int {
        interactionState.activeOwnerCount()
    }

    public struct PrefetchStatus: Sendable, Equatable {
        public let enabled: Bool
        public let paused: Bool
        public let diskThumbnailCoverageFraction: Double
        public let diskThumbnailTotal: Int
        public let diskCoverageVerified: Bool
        public let currentQueueLength: Int
        public let downloadsInFlight: Int
        public let decodesInFlight: Int
        public let lastErrors: [String]
        public let cacheSizeBytes: Int64
        public let diskFileCount: Int
        public let ramDecodedCount: Int
        public let ramDecodedBytes: Int
        public let activeJobs: Int
        public let completed: Int
        public let failed: Int
        /// Classified breakdown of `failed` (their sum equals `failed`).
        public let failedTimeout: Int
        public let failedBatchError: Int
        public let failedItemError: Int
        public let failedUnreported: Int
        /// Withheld because the photo's read authorization changed during the download; retried, never quarantined.
        public let failedWithheld: Int
        public let diskHit: Int
        public let downloadStarted: Int
        public let downloadCompleted: Int
        public let decodeStarted: Int
        public let decodeCompleted: Int
        /// Items currently quarantined because the backend refused them per item this crawl.
        public let unfetchableCount: Int
        public let skippedUnfetchable: Int
        public let pausedReason: String
    }

    public func prefetchStatus() -> PrefetchStatus {
        let coverage = diskPresence.coverage()
        let decodedMetrics = decoded.metrics()
        let reportedSequentialRemaining = sequential.dropFirst(min(sequentialIndex, sequential.count)).reduce(into: 0) {
            count, uid in
            if isReportedForPrefetch(uid) { count += 1 }
        }
        let pausedReason: String
        if !prefetchEnabled {
            pausedReason = "disabled"
        } else if prefetchPaused {
            pausedReason = "manual"
        } else {
            pausedReason = "none"
        }
        return PrefetchStatus(
            enabled: prefetchEnabled,
            paused: prefetchPaused,
            diskThumbnailCoverageFraction: coverage.percent,
            diskThumbnailTotal: coverage.total,
            diskCoverageVerified: coverageSettled,
            currentQueueLength: priority.count + reportedSequentialRemaining
                + withheldRetry.filter(isReportedForPrefetch).count,
            downloadsInFlight: downloadInFlight,
            decodesInFlight: decodeInFlight,
            lastErrors: lastErrors,
            cacheSizeBytes: 0,
            diskFileCount: coverage.present,
            ramDecodedCount: decodedMetrics.entryCount,
            ramDecodedBytes: decodedMetrics.byteCost,
            activeJobs: downloadInFlight + decodeInFlight,
            completed: prefetchCompleted,
            failed: prefetchFailed,
            failedTimeout: prefetchFailedTimeout,
            failedBatchError: prefetchFailedBatchError,
            failedItemError: prefetchFailedItemError,
            failedUnreported: prefetchFailedUnreported,
            failedWithheld: prefetchFailedWithheld,
            diskHit: prefetchDiskHit,
            downloadStarted: prefetchDownloadStarted,
            downloadCompleted: prefetchDownloadCompleted,
            decodeStarted: prefetchDecodeStarted,
            decodeCompleted: prefetchDecodeCompleted,
            unfetchableCount: unfetchable.count(intersecting: prefetchReportingUIDs),
            skippedUnfetchable: skippedUnfetchable,
            pausedReason: pausedReason
        )
    }

    private func startWorkers() {
        guard !workersRunning else { return }
        workersRunning = true
        workerStarts &+= 1
        let generation = prefetchGeneration
        let workers: [Task<Void, Never>] = (0..<configuration.downloadConcurrencyLimit).map { _ in
            Task { [weak self] in
                guard let self else { return }
                await self.worker(generation: generation)
            }
        }
        workerTasks = workers
        workerTask = Task { [weak self, workers] in
            for worker in workers {
                await worker.value
            }
            guard let self else { return }
            #if DEBUG
                self.testingHooks.beforeWorkersStopped()
            #endif
            await self.workersStopped(generation: generation)
        }
    }

    private func workersStopped(generation: UInt64) {
        guard generation == prefetchGeneration else { return }
        workerTasks.removeAll(keepingCapacity: false)
        workerTask = nil
        workersRunning = false
        // A wake that ran before this stop found the workers still running, so the remaining crawl restarts here: the
        // rest of the library, photos withheld for a retry, or an end-of-crawl coverage check that a hold stopped.
        let crawlRemains =
            sequentialIndex < sequential.count || (prefetchEnabled && !withheldRetry.isEmpty)
            || (prefetchEnabled && !sequential.isEmpty && !coverageSettled)
        // Workers of a session that ended would stop at once again; the new session's feed starts its own.
        guard ownerLeaseIsCurrent() else { return }
        if !priority.isEmpty || (crawlRemains && crawlWakeTask == nil) { startWorkers() }
    }

    /// The crawl waits while the device is nearly full, because the cache cannot keep what it downloads, and while the
    /// app is suspended. Visible photos still load. In a background window of iOS it runs under the coordinator's
    /// permit instead (`backgroundWindowPermit`).
    private nonisolated static func holdsCrawl(_ snapshot: LibraryRuntimeSnapshot) -> Bool {
        snapshot.storagePressure == .critical || snapshot.executionOpportunity == .suspended
    }

    /// In a background window every batch waits for the coordinator's single heavy permit, so a waiting backup item
    /// goes first and batches run one at a time. Nil in the foreground, where the crawl runs as before, and when the
    /// window ends during the wait.
    private func backgroundWindowPermit() async -> LibraryBackgroundWindowPermit? {
        let id = UUID()
        let wait = Task { [resourceCoordinator, cache] in
            await LibraryBackgroundWindowPermit.acquire(
                LibraryBackgroundWorkTuning.crawlBatch, coordinator: resourceCoordinator,
                runtimeState: cache.runtimeState)
        }
        windowPermitWaits[id] = wait
        defer { windowPermitWaits[id] = nil }
        return await withTaskCancellationHandler {
            await wait.value
        } onCancel: {
            wait.cancel()
        }
    }

    /// A photo on screen does not wait behind the crawl's permit: the waiting workers stop waiting and take it.
    private func endWindowPermitWaits() {
        for wait in windowPermitWaits.values { wait.cancel() }
    }

    /// Coverage work may run with a permit that need not stop, or in the foreground (active or inactive), never
    /// while suspended and never in a window without a permit.
    private nonisolated func coverageMayRun(_ permit: LibraryBackgroundWindowPermit?) -> Bool {
        if let permit { return !permit.mustStop }
        return cache.runtimeState.snapshot().executionOpportunity < .backgroundPermitted
    }

    private nonisolated func isInBackgroundWindow() -> Bool {
        cache.runtimeState.snapshot().executionOpportunity == .backgroundPermitted
    }

    /// The pause after a permit wait that ended while the app is still, or again, in a background window: a new
    /// window began or the account changed. It keeps that rare case from spinning.
    private static let windowPermitRetryDelay: Duration = .milliseconds(50)

    private nonisolated func crawlIsHeld() -> Bool {
        Self.holdsCrawl(cache.runtimeState.snapshot())
    }

    /// The workers stop instead of polling while only the held crawl remains. Visible demand still starts them.
    private func sleepUntilCrawlMayRun() {
        guard crawlWakeTask == nil else { return }
        let runtimeState = cache.runtimeState
        let generation = prefetchGeneration
        crawlWakeTask = Task { [weak self] in
            for await snapshot in runtimeState.updates() where !Self.holdsCrawl(snapshot) {
                break
            }
            guard !Task.isCancelled else { return }
            await self?.crawlMayRun(generation: generation)
        }
    }

    private func crawlMayRun(generation: UInt64) {
        guard generation == prefetchGeneration else { return }
        crawlWakeTask = nil
        startWorkers()
    }

    private func cancelCrawlWake() {
        guard let crawlWakeTask else { return }
        crawlWakeTask.cancel()
        retiredWorkerTasks.append(crawlWakeTask)
        self.crawlWakeTask = nil
    }

    private func worker(generation: UInt64) async {
        while !Task.isCancelled, generation == prefetchGeneration {
            guard ownerLeaseIsCurrent() else { return }
            // In a background window a crawl batch runs only under the coordinator's single heavy permit, so a
            // waiting backup item goes first; the permit ends with this batch. A photo on screen loads as before.
            // The batch first waits for a free download slot, without the permit and without photos, so nothing
            // waits while it holds either; then it takes the permit and counts its slot before it takes photos.
            var windowPermit: LibraryBackgroundWindowPermit?
            var countedSlot = false
            if priority.isEmpty, isInBackgroundWindow() {
                while activeDownloaders + timedOutLoaders >= targetConcurrency, !Task.isCancelled,
                    generation == prefetchGeneration, ownerLeaseIsCurrent()
                {
                    #if DEBUG
                        downloadSlotWaitHookForTesting?()
                    #endif
                    try? await Task.sleep(for: .milliseconds(60))
                }
                guard !Task.isCancelled, generation == prefetchGeneration, ownerLeaseIsCurrent() else { return }
                // A photo on screen that arrived during the slot wait loads without the crawl's permit, as at the top.
                windowPermit = priority.isEmpty ? await backgroundWindowPermit() : nil
                #if DEBUG
                    await windowPermitReturnHookForTesting?()
                #endif
                // No suspension from here to the count: the state that admitted the batch is the state it runs in.
                guard !Task.isCancelled, generation == prefetchGeneration, ownerLeaseIsCurrent() else {
                    windowPermit?.release()
                    return
                }
                if let permit = windowPermit {
                    guard activeDownloaders + timedOutLoaders < targetConcurrency, !permit.mustStop else {
                        permit.release()
                        continue
                    }
                    activeDownloaders += 1
                    countedSlot = true
                }
            }
            defer {
                windowPermit?.release()
                if countedSlot { activeDownloaders = max(0, activeDownloaders - 1) }
            }
            #if DEBUG
                testingHooks.afterWindowPermitWait()
            #endif
            // A wait that ended without a permit decides again from the state now: a new window waits again.
            let crawlAllowed = windowPermit != nil || !isInBackgroundWindow()
            if !crawlAllowed, priority.isEmpty {
                try? await Task.sleep(for: Self.windowPermitRetryDelay)
                continue
            }
            let work = await takeBatch(crawlAllowed: crawlAllowed)
            // Every exit of this iteration gives the returned reservations back; the download path below also
            // releases them as soon as the load ends.
            defer { releasePriorityReservations(for: work.uids, generation: generation) }
            guard ownerLeaseIsCurrent() else { return }
            // Local pending photos load from the device on their own queue; an iCloud wait never holds back
            // Proton downloads or counts against the network pacing.
            let localChunk = work.uids.filter(\.isLocalPending)
            if !localChunk.isEmpty {
                submitLocalDemand(localChunk.map { ($0, Int(configuration.targetPixels)) }, replacing: false)
                releasePriorityReservations(for: localChunk, generation: generation)
                if localChunk.count == work.uids.count { continue }
            }
            let chunk = localChunk.isEmpty ? work.uids : work.uids.filter { !$0.isLocalPending }
            if chunk.isEmpty {
                if priority.isEmpty && sequentialIndex >= sequential.count
                    && (withheldRetry.isEmpty || !prefetchEnabled)
                {
                    // Coverage is crawl work, decided from the state now, after every wait since the batch: with a permit
                    // that need not stop, or in the foreground. A held crawl sleeps; a window without a permit asks for
                    // one in the next round.
                    guard coverageMayRun(windowPermit) else {
                        if crawlIsHeld() {
                            sleepUntilCrawlMayRun()
                            return
                        }
                        continue
                    }
                    if diskProbeBatchesInFlight > 0 {
                        windowPermit?.release()
                        try? await Task.sleep(for: .milliseconds(10))
                        continue
                    }
                    // Coverage is verified for this crawl; nothing remains.
                    if coverageSettled { return }
                    // Never re-scan while a viewport is actively warming (recent visible demand) - it would
                    // compete for the serial actor with the visible decode that demand represents. Idle; the
                    // scan resumes once demand quiets.
                    if recentVisibleDemand() {
                        windowPermit?.release()
                        try? await Task.sleep(for: .milliseconds(150))
                        continue
                    }
                    // Single-flight: exactly one worker runs the end-of-crawl coverage refresh; the rest idle
                    // (staying available for a demand burst) rather than each scanning. Combined with the
                    // chunked, demand-aborting `runCoverageRefresh`, this means one bounded refresh per drain,
                    // never a stampede of N full-library scans on the serial actor.
                    guard !coverageRefreshInFlight else {
                        windowPermit?.release()
                        try? await Task.sleep(for: .milliseconds(150))
                        continue
                    }
                    coverageRefreshInFlight = true
                    // Under a permit the refresh also stops when the coordinator asks for the permit back or the
                    // window ends; the release below then lets a waiting backup item go first.
                    let outcome = await runCoverageRefresh(shouldStop: { [windowPermit] in
                        !self.coverageMayRun(windowPermit)
                    })
                    coverageRefreshInFlight = false
                    switch outcome {
                    case .aborted:
                        continue  // A live viewport, a stop or a changed session; the loop decides again.
                    case .recrawl:
                        sequentialIndex = 0
                        coverageScanCursor = 0
                        windowPermit?.release()
                        try? await Task.sleep(for: .seconds(2))
                        continue
                    case .settled:
                        coverageSettled = true  // Coverage is settled; stop rescanning this crawl.
                        return
                    }
                }
                // A disk-hit-only batch made real forward progress. Continue immediately: the probe already
                // ran on the utility executor and the next iteration will observe a newly arrived visible-demand
                // signal before reserving more crawl candidates. Do not delay after a disk-hit-only batch.
                if work.probedDisk { continue }
                // A held crawl stops instead of waking every 150 ms until storage recovers or the app returns to
                // the foreground.
                if priority.isEmpty, crawlIsHeld() {
                    sleepUntilCrawlMayRun()
                    return
                }
                windowPermit?.release()
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            if countedSlot {
                // The slot was counted before the batch; a cancellation or a new generation meanwhile starts no
                // loader, and the deferred release gives the slot back.
                guard !Task.isCancelled, generation == prefetchGeneration, ownerLeaseIsCurrent() else { return }
                countedSlot = false
            } else {
                while activeDownloaders + timedOutLoaders >= targetConcurrency, !Task.isCancelled {
                    #if DEBUG
                        downloadSlotWaitHookForTesting?()
                    #endif
                    try? await Task.sleep(for: .milliseconds(60))
                }
                if Task.isCancelled { return }
                // Nothing is counted before the lease check: a worker that stops here has no other way to give the
                // download slot and the in-flight items back.
                guard ownerLeaseIsCurrent() else { return }
                activeDownloaders += 1
            }
            downloadInFlight += chunk.count
            let batchID = UUID()
            batchesInFlight[batchID] = Set(chunk)
            prefetchDownloadStarted += reportedCount(in: chunk)
            diagnostics.recordNetworkRequestDuringPinch()
            let writerGeneration = cache.captureWriterGeneration()
            let snapshot = await Self.loadBatch(
                chunk,
                loader: loader,
                cache: cache,
                diskPresence: diskPresence,
                writerGeneration: writerGeneration,
                sessionLease: ownerSessionLease,
                writeExecutor: decodeExecutor,
                writePermits: decodePermits,
                priority: work.priority,
                seconds: configuration.downloadTimeoutSeconds,
                decodePixelSize: configuration.targetPixels,
                publishMemoryOnly: { [weak self] uid, image in
                    await self?.publishMemoryOnlyArrival(image, for: uid, writerGeneration: writerGeneration) ?? false
                }
            )
            activeDownloaders = max(0, activeDownloaders - 1)
            releasePriorityReservations(for: chunk, generation: generation)
            if let lateLoader = snapshot.lateLoader {
                timedOutLoaders += 1
                let taskID = UUID()
                let tracker = Task { [weak self] in
                    _ = await lateLoader.value
                    await self?.timedOutLoaderFinished(taskID: taskID, batchID: batchID, itemCount: chunk.count)
                }
                timedOutLoaderTasks[taskID] = tracker
            } else {
                downloadInFlight = max(0, downloadInFlight - chunk.count)
                batchesInFlight[batchID] = nil
            }
            guard generation == prefetchGeneration, ownerLeaseIsCurrent() else { return }
            let completed = snapshot.delivered.count
            let reportedDelivered = snapshot.delivered.filter(isReportedForPrefetch)
            prefetchCompleted += reportedDelivered.count
            prefetchDownloadCompleted += reportedDelivered.count
            recordCheckpointPresent(Array(snapshot.storedOnDisk), writerGeneration: writerGeneration)
            let undelivered = chunk.filter { !snapshot.delivered.contains($0) }
            let reportedUndelivered = undelivered.filter(isReportedForPrefetch)
            prefetchFailed += reportedUndelivered.count
            var networkSuspect = false  // batch/timeout/unreported failures point at transport, not content
            switch snapshot.resolution {
            case .timedOut:
                prefetchFailedTimeout += reportedUndelivered.count
                networkSuspect = true
                recordError(
                    "thumbnail batch timed out after \(configuration.downloadTimeoutSeconds)s (\(completed)/\(chunk.count) delivered)"
                )
            case .finished(let result):
                if let batchError = result.batchError {
                    prefetchFailedBatchError += reportedUndelivered.count
                    networkSuspect = true
                    recordError("thumbnail batch failed (\(completed)/\(chunk.count) delivered): \(batchError)")
                } else if !undelivered.isEmpty {
                    let refused = undelivered.filter { result.itemErrors[$0] != nil }
                    prefetchFailedItemError += refused.filter(isReportedForPrefetch).count
                    scheduleRefusalLapseWake(unfetchable.formUnion(refused))
                    if let first = refused.first, let reason = result.itemErrors[first] {
                        recordError(
                            "thumbnail refused for \(refused.count) item(s), e.g. \(Self.key(first)): \(reason)")
                    }
                    // Withheld after an authorization change: not the photo's fault. The crawl requests it again with
                    // a fresh authorization, a bounded number of times; a visible request always does.
                    let withheld = undelivered.filter {
                        result.itemErrors[$0] == nil && result.withheldUIDs.contains($0)
                    }
                    prefetchFailedWithheld += withheld.filter(isReportedForPrefetch).count
                    if let first = withheld.first {
                        recordError(
                            "thumbnail withheld for \(withheld.count) item(s) after an authorization change, e.g. \(Self.key(first))"
                        )
                    }
                    requeueWithheld(withheld)
                    let unreported = undelivered.count - refused.count - withheld.count
                    let reportedUnreported = reportedUndelivered.filter {
                        result.itemErrors[$0] == nil && !result.withheldUIDs.contains($0)
                    }.count
                    prefetchFailedUnreported += reportedUnreported
                    if unreported > 0 {
                        networkSuspect = true
                        recordError("thumbnail batch missing \(unreported)/\(chunk.count) with no reported reason")
                    }
                }
            }
            if completed == 0, !chunk.isEmpty {
                crawlBackoffUntil = clock().addingTimeInterval(configuration.crawlBackoffSeconds)
                if networkSuspect {
                    targetConcurrency = max(configuration.minimumDownloadConcurrency, targetConcurrency / 2)
                }
                aimdSuccessStreak = 0
            } else if completed > 0 {
                aimdSuccessStreak += 1
                if aimdSuccessStreak >= 4 {
                    aimdSuccessStreak = 0
                    targetConcurrency = min(configuration.downloadConcurrencyLimit, targetConcurrency + 1)
                }
            }
            // Arrival wake: bytes just landed on disk. If a viewport is recently live, tell the host to
            // re-warm missing visible cells from disk and redraw.
            if completed > 0 {
                cacheArrivalWake.call()
                replayVisibleDiskDecodeDemand()
                if hostArrivalWakeIsLive(now: clock()) {
                    imagesAvailableWake.call()
                }
            }
            emitPrefetchSummary()
        }
    }

    private enum BatchResolution: Sendable {
        case finished(ThumbnailBatchLoadResult)
        case timedOut
    }

    private struct BatchSnapshot: Sendable {
        let delivered: Set<PhotoUID>
        /// The delivered subset that reached the disk cache. The rest is held in memory only.
        let storedOnDisk: Set<PhotoUID>
        let resolution: BatchResolution
        let lateLoader: Task<ThumbnailBatchLoadResult, Never>?
    }

    private struct BatchWork: Sendable {
        var uids: [PhotoUID] = []
        var priority: ThumbnailPriority = .idleLibraryCrawl
        var probedDisk = false
    }

    private struct DirectDecodeFlight {
        let id: UInt64
        let task: Task<DecodedThumbnail?, Never>
    }

    private struct DiskProbe: Sendable {
        let uid: PhotoUID
        let usable: Bool
    }

    /// Runs one loader batch against a real wall-clock timeout. Cancellation is forwarded to the
    /// loader when the deadline wins. The loader task remains accounted for until it actually
    /// returns, so a cancellation-ignoring transport still cannot create unbounded hidden work.
    /// Late deliveries may land in the disk cache, but counters snapshot exactly once here: an
    /// item is either delivered-by-resolution or failed, never both.
    private nonisolated static func loadBatch(
        _ chunk: [PhotoUID],
        loader: ThumbnailBatchLoader,
        cache: ThumbnailCache,
        diskPresence: DiskPresenceCache,
        writerGeneration: CacheWriterGeneration.Token,
        sessionLease: CacheWriterGeneration.SessionToken,
        writeExecutor: ThumbnailDecodeWorkExecutor,
        writePermits: DecodePermitPool,
        priority: ThumbnailPriority,
        seconds: Double,
        decodePixelSize: CGFloat,
        publishMemoryOnly: @escaping @Sendable (PhotoUID, DecodedThumbnail) async -> Bool
    ) async -> BatchSnapshot {
        let delivered = UIDSetBox()
        let storedOnDisk = UIDSetBox()
        let writes = ThumbnailWriteTaskGroup()
        let onLoaded: @Sendable (PhotoUID, Data) -> Void = { uid, data in
            writes.submit {
                guard cache.isCurrentSessionLease(sessionLease) else { return }
                guard await writePermits.acquire(priority: priority) else { return }
                let (stored, memoryOnly) = await writeExecutor.perform(priority: priority) {
                    let stored = cache.storeToDisk(data, for: uid, ifCurrent: writerGeneration)
                    // A nearly full device keeps thumbnails in memory only. Decode now, or the downloaded bytes
                    // are lost and the tile stays blank while the same thumbnail is requested again.
                    guard stored == .storagePaused else { return (stored, nil as DecodedThumbnail?) }
                    return (stored, ThumbnailImageDecoder.downsample(data, maxPixelSize: decodePixelSize))
                }
                await writePermits.release()
                guard cache.isCurrentSessionLease(sessionLease) else { return }
                switch stored {
                case .stored:
                    diskPresence.set(uid, present: true)
                    storedOnDisk.insert(uid)
                    delivered.insert(uid)
                case .storagePaused:
                    guard let memoryOnly, await publishMemoryOnly(uid, memoryOnly) else { return }
                    delivered.insert(uid)
                case .stale, .ioFailure:
                    return
                }
            }
        }
        let loaderTask = Task {
            if let priorityLoader = loader as? any PriorityThumbnailBatchLoader {
                await priorityLoader.loadThumbnails(for: chunk, priority: priority, onLoaded: onLoaded)
            } else {
                await loader.loadThumbnails(for: chunk, onLoaded: onLoaded)
            }
        }
        let completionTask = Task {
            let result = await loaderTask.value
            await writes.finishAndWait()
            return result
        }
        let resolutionGate = OneShotContinuation<BatchResolution>()
        let resolution: BatchResolution = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard resolutionGate.install(continuation) else { return }
                let timeoutTask = Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    guard !Task.isCancelled else { return }
                    if resolutionGate.resolve(.timedOut) {
                        loaderTask.cancel()
                    }
                }
                Task {
                    let result = await completionTask.value
                    if resolutionGate.resolve(.finished(result)) {
                        timeoutTask.cancel()
                    }
                }
            }
        } onCancel: {
            // Resume the cancelled crawl worker immediately. The returned loader handle remains
            // tracked and owner teardown still joins it before releasing the backend.
            loaderTask.cancel()
            _ = resolutionGate.resolve(.timedOut)
        }
        let lateLoader: Task<ThumbnailBatchLoadResult, Never>?
        if case .timedOut = resolution {
            // This completion includes callback disk writes. Owner teardown must not release the account/cache
            // graph while a late write still owns its generation and utility-executor operation.
            lateLoader = completionTask
        } else {
            lateLoader = nil
        }
        return BatchSnapshot(
            delivered: delivered.snapshot,
            storedOnDisk: storedOnDisk.snapshot,
            resolution: resolution,
            lateLoader: lateLoader
        )
    }

    private func timedOutLoaderFinished(taskID: UUID, batchID: UUID, itemCount: Int) {
        timedOutLoaderTasks[taskID] = nil
        timedOutLoaders = max(0, timedOutLoaders - 1)
        downloadInFlight = max(0, downloadInFlight - itemCount)
        batchesInFlight[batchID] = nil
    }

    /// Reserves queue candidates on the actor, then yields it while the dedicated executor performs the actual
    /// file reads and AES-GCM validation. The old implementation called `hasUsableDiskData` inline here; one
    /// pathological APFS read could therefore stop every viewport replacement for multiple seconds.
    private func takeBatch(crawlAllowed: Bool = true) async -> BatchWork {
        let probeGeneration = cache.captureWriterGeneration()
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
            return BatchWork()
        }
        var candidates: [PhotoUID] = []
        var reserved = Set<PhotoUID>()
        var batchPriority = ThumbnailPriority.idleLibraryCrawl
        var diskHits: [PhotoUID] = []
        var diskMisses: [PhotoUID] = []
        // A batch that ends empty (lost lease, fenced or aborted probe) never reaches the worker's own release,
        // so every priority reservation not handed over in the returned batch is given back here. The generation
        // is the one that reserved, so a newer generation keeps its own reservation.
        let reservationGeneration = prefetchGeneration
        var reservedPriority: [PhotoUID] = []
        var handedOver = Set<PhotoUID>()
        defer {
            releasePriorityReservations(
                for: reservedPriority.filter { !handedOver.contains($0) },
                generation: reservationGeneration
            )
        }
        while candidates.count < configuration.batchSize, !priority.isEmpty {
            let bestIndex =
                priority.indices.min {
                    let lhs = priorityByUID[priority[$0]] ?? .idleLibraryCrawl
                    let rhs = priorityByUID[priority[$1]] ?? .idleLibraryCrawl
                    if lhs != rhs { return lhs < rhs }
                    // Preserve the caller's near-to-far order inside one priority. The former LIFO tie break
                    // inverted a scroll-ahead corridor, downloading its far edge before the cells about to enter
                    // the viewport.
                    return $0 < $1
                } ?? priority.index(before: priority.endIndex)
            let uid = priority.remove(at: bestIndex)
            let itemPriority = priorityByUID.removeValue(forKey: uid) ?? .idleLibraryCrawl
            batchPriority = min(batchPriority, itemPriority)
            if unfetchable.contains(uid) {
                if isReportedForPrefetch(uid) { skippedUnfetchable += 1 }
                continue
            }
            // Priority work always revalidates. A durable checkpoint can outlive an evicted or corrupt cache
            // file; trusting it here would leave a stable visible placeholder with no subsequent network wake.
            guard reserved.insert(uid).inserted else { continue }
            priorityReservations.append(
                PriorityReservation(
                    uid: uid,
                    priority: itemPriority,
                    generation: prefetchGeneration
                ))
            reservedPriority.append(uid)
            candidates.append(uid)
        }

        let now = clock()
        let backingOff = crawlBackoffUntil.map { now < $0 } ?? false
        // A nearly full device or a background window holds the crawl; visible photos still load.
        guard crawlAllowed, !prefetchPaused, prefetchEnabled, !recentVisibleDemand(now: now), !backingOff,
            !crawlIsHeld()
        else {
            let batch = await finishDiskProbeBatch(
                candidates,
                priority: batchPriority,
                writerGeneration: probeGeneration,
                forceAuthentication: startupAuthenticationPending
            )
            handedOver = Set(batch.uids)
            if startupAuthenticationPending,
                sequentialIndex >= sequential.count,
                candidates.isEmpty || batch.probedDisk
            {
                completeStartupAuthentication()
            }
            return batch
        }

        // Withheld photos first: the crawl reached them before. They pass the same gates as the crawl.
        while candidates.count < configuration.batchSize, !withheldRetry.isEmpty {
            let uid = withheldRetry.removeFirst()
            guard readAllowed(uid), !unfetchable.contains(uid), reserved.insert(uid).inserted else { continue }
            candidates.append(uid)
        }

        var scannedThisCall = 0
        while candidates.count < configuration.batchSize,
            sequentialIndex < sequential.count,
            scannedThisCall < configuration.sequentialScanLimit
        {
            scannedThisCall += 1
            let uid = sequential[sequentialIndex]
            sequentialIndex += 1
            if unfetchable.contains(uid) {
                if isReportedForPrefetch(uid) { skippedUnfetchable += 1 }
                continue
            }
            if checkpointPresent.contains(uid) {
                guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
                    return BatchWork()
                }
                diskPresence.set(uid, present: true)
                if isReportedForPrefetch(uid) { prefetchDiskHit += 1 }
                continue
            }
            guard reserved.insert(uid).inserted else { continue }
            candidates.append(uid)
        }
        guard !candidates.isEmpty else {
            if startupAuthenticationPending, sequentialIndex >= sequential.count {
                completeStartupAuthentication()
            }
            return BatchWork(priority: batchPriority)
        }
        let forceAuthentication = startupAuthenticationPending
        guard
            let probes = await accountedDiskProbes(
                candidates,
                priority: batchPriority,
                writerGeneration: probeGeneration,
                forceAuthentication: forceAuthentication
            )
        else {
            return BatchWork()
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
            return BatchWork()
        }
        for probe in probes {
            guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
                return BatchWork()
            }
            diskPresence.set(probe.uid, present: probe.usable)
            if probe.usable {
                diskHits.append(probe.uid)
                if isReportedForPrefetch(probe.uid) { prefetchDiskHit += 1 }
            } else {
                diskMisses.append(probe.uid)
            }
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
            return BatchWork()
        }
        recordCheckpointPresent(diskHits, writerGeneration: probeGeneration)
        recordCheckpointMissing(diskMisses, writerGeneration: probeGeneration)
        releasePriorityReservations(for: diskHits, generation: prefetchGeneration)
        if forceAuthentication, sequentialIndex >= sequential.count {
            completeStartupAuthentication()
        }
        handedOver = Set(diskMisses)
        return BatchWork(uids: diskMisses, priority: batchPriority, probedDisk: !candidates.isEmpty)
    }

    private func completeStartupAuthentication() {
        startupAuthenticationPending = false
        authenticatedCrawlCompleted = true
    }

    private func finishDiskProbeBatch(
        _ candidates: [PhotoUID],
        priority: ThumbnailPriority,
        writerGeneration: CacheWriterGeneration.Token,
        forceAuthentication: Bool
    ) async -> BatchWork {
        guard !candidates.isEmpty else { return BatchWork(priority: priority) }
        guard
            let probes = await accountedDiskProbes(
                candidates,
                priority: priority,
                writerGeneration: writerGeneration,
                forceAuthentication: forceAuthentication
            )
        else {
            return BatchWork()
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(writerGeneration) else {
            return BatchWork()
        }
        var misses: [PhotoUID] = []
        var hits: [PhotoUID] = []
        for probe in probes {
            guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(writerGeneration) else {
                return BatchWork()
            }
            diskPresence.set(probe.uid, present: probe.usable)
            if probe.usable {
                hits.append(probe.uid)
                if isReportedForPrefetch(probe.uid) { prefetchDiskHit += 1 }
            } else {
                misses.append(probe.uid)
            }
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(writerGeneration) else {
            return BatchWork()
        }
        recordCheckpointPresent(hits, writerGeneration: writerGeneration)
        recordCheckpointMissing(misses, writerGeneration: writerGeneration)
        releasePriorityReservations(for: hits, generation: prefetchGeneration)
        return BatchWork(uids: misses, priority: priority, probedDisk: !candidates.isEmpty)
    }

    private func accountedDiskProbes(
        _ uids: [PhotoUID],
        priority: ThumbnailPriority,
        writerGeneration: CacheWriterGeneration.Token,
        forceAuthentication: Bool
    ) async -> [DiskProbe]? {
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(writerGeneration) else {
            return nil
        }
        let generation = prefetchGeneration
        diskProbeBatchesInFlight += 1
        defer { diskProbeBatchesInFlight = max(0, diskProbeBatchesInFlight - 1) }
        let probes = await probeUsableDisk(
            uids,
            priority: priority,
            writerGeneration: writerGeneration,
            sessionLease: ownerSessionLease,
            forceAuthentication: forceAuthentication
        )
        guard generation == prefetchGeneration,
            prefetchEnabled,
            ownerLeaseIsCurrent(),
            cache.isCurrentWriterGeneration(writerGeneration),
            let probes
        else {
            return nil
        }
        return probes
    }

    private nonisolated func probeUsableDisk(
        _ uids: [PhotoUID],
        priority: ThumbnailPriority,
        writerGeneration: CacheWriterGeneration.Token,
        sessionLease: CacheWriterGeneration.SessionToken,
        forceAuthentication: Bool
    ) async -> [DiskProbe]? {
        let cache = self.cache
        let executor = self.decodeExecutor
        guard cache.isCurrentSessionLease(sessionLease),
            cache.isCurrentWriterGeneration(writerGeneration)
        else {
            return nil
        }
        #if DEBUG
            let testingHooks = self.testingHooks
        #endif
        let probes = await executor.perform(priority: priority) { () -> [DiskProbe]? in
            var probes: [DiskProbe] = []
            probes.reserveCapacity(uids.count)
            for uid in uids {
                guard cache.isCurrentSessionLease(sessionLease),
                    cache.isCurrentWriterGeneration(writerGeneration)
                else {
                    return nil
                }
                #if DEBUG
                    testingHooks.beforeDiskProbe()
                #endif
                self.diagnostics.recordDiskPresenceCheckDuringPinch()
                let usable =
                    forceAuthentication
                    ? cache.hasAuthenticatedDiskData(uid)
                    : cache.hasUsableDiskData(uid)
                probes.append(DiskProbe(uid: uid, usable: usable))
            }
            return probes
        }
        guard cache.isCurrentSessionLease(sessionLease),
            cache.isCurrentWriterGeneration(writerGeneration)
        else {
            return nil
        }
        return probes
    }

    @discardableResult
    private func removeQueuedPriorities(_ removedPriorities: Set<ThumbnailPriority>) -> Int {
        var removed = 0
        priority.removeAll { uid in
            guard let value = priorityByUID[uid], removedPriorities.contains(value) else { return false }
            priorityByUID.removeValue(forKey: uid)
            removed += 1
            return true
        }
        return removed
    }

    private func trimPriorityQueueIfNeeded() {
        while priority.count > configuration.priorityQueueLimit {
            // Discard the least urgent, farthest queued item. Equal priorities remain FIFO so the next
            // near-viewport item is retained.
            let index =
                priority.indices.max { lhs, rhs in
                    let left = priorityByUID[priority[lhs]] ?? .idleLibraryCrawl
                    let right = priorityByUID[priority[rhs]] ?? .idleLibraryCrawl
                    if left != right { return left < right }
                    return lhs < rhs
                } ?? priority.index(before: priority.endIndex)
            let uid = priority.remove(at: index)
            priorityByUID.removeValue(forKey: uid)
        }
    }

    private func restorePriorityReservationsForRestart() {
        for reservation in priorityReservations {
            if let queuedPriority = priorityByUID[reservation.uid] {
                priorityByUID[reservation.uid] = min(queuedPriority, reservation.priority)
            } else {
                priority.append(reservation.uid)
                priorityByUID[reservation.uid] = reservation.priority
            }
        }
        priorityReservations.removeAll(keepingCapacity: true)
        trimPriorityQueueIfNeeded()
    }

    private func releasePriorityReservations(for uids: [PhotoUID], generation: UInt64) {
        guard !uids.isEmpty else { return }
        let released = Set(uids)
        priorityReservations.removeAll { reservation in
            reservation.generation == generation && released.contains(reservation.uid)
        }
    }

    /// Whether a viewport has demanded thumbnails within the quiet window. `nonisolated` (reads the lock-guarded
    /// demand box), so the crawl can consult it mid-scan without touching actor state.
    private nonisolated func recentVisibleDemand(now: Date? = nil) -> Bool {
        guard let last = lastDemand.get() else { return false }
        return (now ?? clock()).timeIntervalSince(last) < configuration.visibleQuietWindow
    }

    /// Bound on disk-presence stats performed per `advanceDiskCoverageScan` invocation - the ceiling on how long
    /// one end-of-crawl coverage step can hold the serial actor. Small enough that a visible warm decode never
    /// waits behind more than this many filesystem stats.
    private static let coverageScanChunk = 512

    /// Advances the end-of-crawl disk-coverage re-scan by one bounded chunk of disk checks, returning the
    /// refreshed coverage only when a full pass just completed (else `nil` - "call again"). Bounded so it can
    /// never hold the serial actor for an O(library) scan, and it bails to `nil` the instant a viewport goes
    /// live, so it can never starve a visible warm decode. Workers share `coverageScanCursor`, so together they
    /// complete one pass in bounded steps; no single worker runs a full scan. All filesystem probes run on the
    /// decode executor, never on this actor.
    /// One step of the end-of-crawl coverage scan.
    private enum CoverageScanStep {
        case finished((present: Int, total: Int, percent: Double))
        case unfinished
        /// The session or the cache writer changed: this feed's scan can never finish.
        case stale
    }

    private func advanceDiskCoverageScan() async -> CoverageScanStep {
        #if DEBUG
            testingHooks.beforeCoverageScanStep()
        #endif
        let cache = self.cache
        let probeGeneration = cache.captureWriterGeneration()
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
            return .stale
        }
        var scanned = 0
        var present: [PhotoUID] = []
        var missing: [PhotoUID] = []
        var needsProbe: [PhotoUID] = []
        while coverageScanCursor < sequential.count, scanned < Self.coverageScanChunk {
            guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
                return .stale
            }
            if recentVisibleDemand() { return .unfinished }
            let uid = sequential[coverageScanCursor]
            if checkpointPresent.contains(uid) {
                guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
                    return .stale
                }
                diskPresence.set(uid, present: true)
                present.append(uid)
            } else {
                needsProbe.append(uid)
            }
            coverageScanCursor += 1
            scanned += 1
        }
        if !needsProbe.isEmpty {
            let probeUIDs = needsProbe
            let probes = await decodeExecutor.perform(priority: .idleLibraryCrawl) { () -> [DiskProbe]? in
                var probes: [DiskProbe] = []
                probes.reserveCapacity(probeUIDs.count)
                for uid in probeUIDs {
                    guard cache.isCurrentSessionLease(self.ownerSessionLease),
                        cache.isCurrentWriterGeneration(probeGeneration)
                    else {
                        return nil
                    }
                    self.diagnostics.recordDiskPresenceCheckDuringPinch()
                    probes.append(DiskProbe(uid: uid, usable: cache.hasUsableDiskData(uid)))
                }
                return probes
            }
            guard let probes,
                ownerLeaseIsCurrent(),
                cache.isCurrentSessionLease(ownerSessionLease),
                cache.isCurrentWriterGeneration(probeGeneration)
            else {
                return .stale
            }
            for probe in probes {
                guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
                    return .stale
                }
                diskPresence.set(probe.uid, present: probe.usable)
                if probe.usable {
                    present.append(probe.uid)
                } else {
                    missing.append(probe.uid)
                }
            }
        }
        guard ownerLeaseIsCurrent(), cache.isCurrentWriterGeneration(probeGeneration) else {
            return .stale
        }
        recordCheckpointPresent(present, writerGeneration: probeGeneration)
        recordCheckpointMissing(missing, writerGeneration: probeGeneration)
        guard coverageScanCursor >= sequential.count else { return .unfinished }  // pass not finished yet
        coverageScanCursor = 0
        return .finished(diskPresence.coverage())
    }

    private func recordCheckpointPresent(
        _ uids: [PhotoUID],
        writerGeneration: CacheWriterGeneration.Token? = nil
    ) {
        guard !uids.isEmpty, ownerLeaseIsCurrent() else { return }
        if let writerGeneration, !cache.isCurrentWriterGeneration(writerGeneration) { return }
        for uid in uids where checkpointPresent.insert(uid).inserted {
            // A current probe proved the hint. Avoid rewriting an unchanged durable entry, but retain the
            // current-session proof in `checkpointPresent` for coverage decisions.
            if checkpointHints.remove(uid) == nil {
                pendingCheckpointUpdates[uid] = true
            }
        }
        flushCheckpointUpdatesIfNeeded(writerGeneration: writerGeneration)
    }

    private func recordCheckpointMissing(
        _ uids: [PhotoUID],
        writerGeneration: CacheWriterGeneration.Token? = nil
    ) {
        guard !uids.isEmpty, ownerLeaseIsCurrent() else { return }
        if let writerGeneration, !cache.isCurrentWriterGeneration(writerGeneration) { return }
        for uid in uids {
            let hadHint = checkpointHints.remove(uid) != nil
            let hadPresent = checkpointPresent.remove(uid) != nil
            if hadHint || hadPresent {
                pendingCheckpointUpdates[uid] = false
            }
        }
        flushCheckpointUpdatesIfNeeded(writerGeneration: writerGeneration)
    }

    private func flushCheckpointUpdatesIfNeeded(writerGeneration: CacheWriterGeneration.Token? = nil) {
        if pendingCheckpointUpdates.count >= Self.checkpointFlushThreshold {
            flushCheckpointUpdates(writerGeneration: writerGeneration)
        }
    }

    private func flushCheckpointUpdates(writerGeneration: CacheWriterGeneration.Token? = nil) {
        guard ownerLeaseIsCurrent() else {
            pendingCheckpointUpdates.removeAll(keepingCapacity: true)
            return
        }
        if let writerGeneration, !cache.isCurrentWriterGeneration(writerGeneration) {
            pendingCheckpointUpdates.removeAll(keepingCapacity: true)
            return
        }
        guard let coverageStore, !pendingCheckpointUpdates.isEmpty else {
            pendingCheckpointUpdates.removeAll(keepingCapacity: true)
            return
        }
        var present: [PhotoUID] = []
        var missing: [PhotoUID] = []
        present.reserveCapacity(pendingCheckpointUpdates.count)
        missing.reserveCapacity(pendingCheckpointUpdates.count)
        for (uid, isPresent) in pendingCheckpointUpdates {
            if isPresent { present.append(uid) } else { missing.append(uid) }
        }
        pendingCheckpointUpdates.removeAll(keepingCapacity: true)
        guard ownerLeaseIsCurrent(),
            writerGeneration.map({ cache.isCurrentWriterGeneration($0) }) ?? true
        else {
            return
        }
        coverageStore.recordPresent(present, for: coverageCheckpointKey)
        guard ownerLeaseIsCurrent(),
            writerGeneration.map({ cache.isCurrentWriterGeneration($0) }) ?? true
        else {
            return
        }
        coverageStore.recordMissing(missing, for: coverageCheckpointKey)
    }

    private enum CoverageRefreshOutcome { case settled, recrawl, aborted }

    /// Runs the end-of-crawl disk-coverage refresh to completion, in bounded `advanceDiskCoverageScan` chunks
    /// that yield the serial actor between them and abort the instant a viewport goes live. Invoked single-flight
    /// (guarded by `coverageRefreshInFlight`), so exactly one runs per drain regardless of worker count - it can
    /// never hold the actor for an O(library) scan, be multiplied by the worker count, or starve a visible warm
    /// decode. Emits one `[ThumbCoverage]` line at start and one at finish (never per item).
    private func runCoverageRefresh(shouldStop: () -> Bool = { false }) async -> CoverageRefreshOutcome {
        defer { flushCheckpointUpdates() }
        let startedAt = clock()
        coverageRefreshStarts += 1
        emitCoverage("refreshStart", scanned: 0, coverage: diskPresence.coverage(), startedAt: startedAt, reason: "-")
        // Known-state fast path: if the incremental tracker already reports (near) complete coverage from this
        // session's crawling, settle without a full `cache.has` sweep - it would be redundant background I/O.
        // The tracker only counts UIDs it has positively seen present, so this can never falsely report "warm"
        // from incomplete knowledge; a real scan runs only when knowledge is incomplete (e.g. a checkpoint
        // resume left early items unscanned) and might reveal missing items to re-crawl.
        let known = diskPresence.coverage()
        if known.percent >= 0.995 {
            emitCoverage("refreshDone", scanned: 0, coverage: known, startedAt: startedAt, reason: "trackerComplete")
            return .settled
        }
        coverageFullScans += 1
        coverageScanCursor = 0
        while true {
            if Task.isCancelled || shouldStop() {
                emitCoverage(
                    "refreshAbortStopped", scanned: coverageScanCursor,
                    coverage: diskPresence.coverage(), startedAt: startedAt, reason: "stopped")
                return .aborted
            }
            if recentVisibleDemand() {
                emitCoverage(
                    "refreshAbortVisibleDemand", scanned: coverageScanCursor,
                    coverage: diskPresence.coverage(), startedAt: startedAt, reason: "visibleDemand")
                return .aborted
            }
            let coverage: (present: Int, total: Int, percent: Double)
            switch await advanceDiskCoverageScan() {
            case .finished(let finished):
                coverage = finished
            case .unfinished:
                try? await Task.sleep(for: .milliseconds(1))  // Yield after each chunk.
                continue
            case .stale:
                emitCoverage(
                    "refreshAbortStale", scanned: coverageScanCursor,
                    coverage: diskPresence.coverage(), startedAt: startedAt, reason: "staleSession")
                return .aborted
            }
            let recrawl = coverage.percent < 0.995 && coverage.percent > lastRepassPercent + 0.01
            if recrawl { lastRepassPercent = coverage.percent }
            emitCoverage(
                "refreshDone", scanned: coverage.total, coverage: coverage, startedAt: startedAt,
                reason: recrawl ? "recrawl" : "settled")
            return recrawl ? .recrawl : .settled
        }
    }

    private func emitCoverage(
        _ event: String, scanned: Int, coverage: (present: Int, total: Int, percent: Double),
        startedAt: Date, reason: String
    ) {
        diagnostics.emit(
            "ThumbCoverage",
            [
                "event": event,
                "scanned": "\(scanned)",
                "total": "\(coverage.total)",
                "present": "\(coverage.present)",
                "durationMs": "\(Int(clock().timeIntervalSince(startedAt) * 1000))",
                "workers": "\(configuration.downloadConcurrencyLimit)",
                "reason": reason,
            ])
    }

    private nonisolated static func decodeTile(
        cache: ThumbnailCache,
        uid: PhotoUID,
        maxPixels: CGFloat,
        isUpgrade: Bool
    ) -> DecodedTile {
        let readStartedAt = Date()
        let data = PhotoPerformanceSignposts.mediaFeed.interval("feed.decrypt") {
            cache.diskData(for: uid)
        }
        let readDurationMs = Date().timeIntervalSince(readStartedAt) * 1000
        guard let data else {
            return DecodedTile(
                uid: uid,
                decoded: nil,
                diskHadData: false,
                readDurationMs: readDurationMs,
                durationMs: 0,
                decodePixelCap: Int(maxPixels),
                isUpgrade: isUpgrade
            )
        }
        let decodeStartedAt = Date()
        let decoded = PhotoPerformanceSignposts.mediaFeed.interval("feed.decode") {
            ThumbnailImageDecoder.downsample(data, maxPixelSize: maxPixels)
        }
        return DecodedTile(
            uid: uid,
            decoded: decoded,
            diskHadData: true,
            readDurationMs: readDurationMs,
            durationMs: Date().timeIntervalSince(decodeStartedAt) * 1000,
            decodePixelCap: Int(maxPixels),
            isUpgrade: isUpgrade
        )
    }

    private func recordSlowDecodeStages(_ tile: DecodedTile) {
        guard tile.readDurationMs >= 250 || tile.durationMs >= 250 else { return }
        diagnostics.emitDebug(
            "ThumbDecode",
            [
                "action": "slowStage",
                "diskHadData": "\(tile.diskHadData)",
                "readMs": "\(Int(tile.readDurationMs))",
                "decodeMs": "\(Int(tile.durationMs))",
            ])
    }

    @discardableResult
    private func storeDecoded(
        _ image: DecodedThumbnail,
        for uid: PhotoUID,
        decodePixelCap: Int,
        access: VisibleThumbnailAccess? = nil
    ) -> DecodedThumbnail? {
        guard ownerLeaseIsCurrent(), readAllowed(uid, access: access) else { return nil }
        let becameCurrent = decoded.set(image, for: uid, decodePixelCap: decodePixelCap)
        guard ownerLeaseIsCurrent() else {
            decoded.removeAll()
            return nil
        }
        guard readAllowed(uid, access: access) else {
            decoded.remove(uid)
            return nil
        }
        if becameCurrent { onDecoded(uid, image) }
        return decoded.image(for: uid)
    }

    // MARK: - Local pending photos

    private nonisolated func readAllowed(_ uid: PhotoUID, access: VisibleThumbnailAccess? = nil) -> Bool {
        if let access {
            return !uid.isLocalPending && access.owner == visibleAccessOwner && access.uid == uid && access.isCurrent
        }
        return uid.isLocalPending
            ? localAuthorization.isAllowed(uid)
            : thumbnailReadAuthorization.isAllowed(uid) || adoptedAuthorization.isAllowed(uid)
    }

    /// Called inside the cache's writer fence. Never re-enter its generation/session lock here.
    /// Scoped operations pass their captured generation separately; the cache validates that generation itself.
    private nonisolated func cacheReadAuthorized(_ uid: PhotoUID, access: VisibleThumbnailAccess) -> Bool {
        return !uid.isLocalPending && access.owner == visibleAccessOwner && access.uid == uid && access.isAuthorized
    }

    /// Installs the device loader for local pending photos.
    public func setLocalThumbnailLoader(_ loader: (any LocalThumbnailLoading)?) {
        localLoader = loader
    }

    /// Replaces the set of local pending photos the feed may show. Images of photos that left the set are
    /// dropped at once; photos that joined get a fresh load attempt. `adoptions` first hand decoded images
    /// to the Proton photos that replaced pending tiles, before their local images are dropped.
    public func setLocalAuthorization(
        _ uids: Set<PhotoUID>,
        adoptions: [(local: PhotoUID, remote: PhotoUID)] = []
    ) {
        var fromDevice: [(local: PhotoUID, remote: PhotoUID)] = []
        for adoption in adoptions where !adoptDecoded(from: adoption.local, to: adoption.remote) {
            // RAM no longer holds the pending image: read it from the device again instead of leaving the tile
            // black until the Proton thumbnail downloads.
            if !adoption.remote.isLocalPending, decoded.image(for: adoption.remote) == nil {
                fromDevice.append(adoption)
            }
        }
        if !fromDevice.isEmpty, let localLoader {
            Task { await self.adoptFromDevice(fromDevice, loader: localLoader) }
        }
        let change = localAuthorization.replace(with: uids.filter(\.isLocalPending))
        for uid in change.removed {
            decoded.remove(uid)
            localFailedAttempts[uid] = nil
            localRetryAt[uid] = nil
            if let load = localLoads[uid], !load.pinned { load.task.cancel() }
        }
        unfetchable.subtract(change.added)
        unfetchable.subtract(change.removed)
        let replay = change.added.compactMap { uid in deniedLocalDemand.removeValue(forKey: uid).map { (uid, $0) } }
        if !replay.isEmpty { submitLocalDemand(replay, replacing: false) }
        // A photo that just joined the grid starts loading now, before its first frame asks for it.
        let preload = change.added.prefix(Self.maxLocalPreload).map { ($0, Int(configuration.targetPixels)) }
        if !preload.isEmpty { submitLocalDemand(preload, replacing: false) }
    }

    /// The handover image read from the device, for a Proton photo whose pending image left RAM.
    private func adoptFromDevice(
        _ adoptions: [(local: PhotoUID, remote: PhotoUID)],
        loader: any LocalThumbnailLoading
    ) async {
        let pixels = Int(configuration.targetPixels)
        let images = await loader.thumbnails(for: adoptions.map(\.local), maxPixelSize: CGFloat(pixels))
        guard ownerLeaseIsCurrent() else { return }
        var stored = false
        for adoption in adoptions {
            // The Proton thumbnail may have arrived meanwhile; it wins.
            guard let image = images[adoption.local], decoded.image(for: adoption.remote) == nil else { continue }
            if !thumbnailReadAuthorization.isAllowed(adoption.remote) {
                adoptedAuthorization.insert(adoption.remote, limit: Self.maxAdoptedWithoutScope)
            }
            if storeDecoded(image, for: adoption.remote, decodePixelCap: pixels) != nil { stored = true }
        }
        // The grid may rest after the handover; wake it so the tile uploads the image.
        if stored { wakeHostsForLocalArrival() }
    }

    /// Loads new images for local photos whose content changed (a new revision) and keeps the old image until
    /// then, so a tile never turns black. Returns the photos whose image was replaced; the host then lets its
    /// grids upload the new image.
    public func refreshLocal(_ uids: [PhotoUID]) async -> [PhotoUID] {
        guard let localLoader else { return [] }
        let targets = uids.filter { $0.isLocalPending && localAuthorization.isAllowed($0) }
        guard !targets.isEmpty else { return [] }
        for uid in targets {
            // A photo that failed while the camera still processed it may load now.
            unfetchable.remove(uid)
            localFailedAttempts[uid] = nil
            localRetryAt[uid] = nil
        }
        // The same size as the image it replaces, so a sharper tile never gets a softer one.
        let pixels = targets.reduce(Int(configuration.targetPixels)) { max($0, decoded.decodePixelCap(for: $1) ?? 0) }
        let images = await localLoader.thumbnails(for: targets, maxPixelSize: CGFloat(pixels))
        guard ownerLeaseIsCurrent() else { return [] }
        var refreshed: [PhotoUID] = []
        for uid in targets where localAuthorization.isAllowed(uid) {
            guard let image = images[uid], storeDecoded(image, for: uid, decodePixelCap: pixels) != nil else {
                continue
            }
            refreshed.append(uid)
        }
        if !refreshed.isEmpty { wakeHostsForLocalArrival() }
        return refreshed
    }

    /// Hands the decoded image of a pending photo to the Proton photo that replaced it, so the tile never
    /// blanks while the remote thumbnail loads. The remote identity must already be authorized.
    @discardableResult
    public func adoptDecoded(from local: PhotoUID, to remote: PhotoUID) -> Bool {
        guard local.isLocalPending, !remote.isLocalPending, decoded.image(for: remote) == nil,
            let image = decoded.image(for: local)
        else { return false }
        if !thumbnailReadAuthorization.isAllowed(remote) {
            adoptedAuthorization.insert(remote, limit: Self.maxAdoptedWithoutScope)
        }
        guard storeDecoded(image, for: remote, decodePixelCap: Int(configuration.targetPixels)) != nil else {
            return false
        }
        notifyHostOfAvailableImageIfVisible()
        return true
    }

    /// The host's viewport needs no more thumbnails: queued local loads drop; running ones finish.
    public func clearLocalVisibleDemand() {
        deniedLocalDemand.removeAll()
        submitLocalDemand([], replacing: true)
    }

    /// A grid left the screen: queued local loads drop and running ones stop, unless a caller waits for them.
    /// Hosts that still show pending photos get a wake and ask again.
    public func endLocalVisibleDemand() {
        localDemand.removeAll()
        deniedLocalDemand.removeAll()
        var cancelled = false
        for load in localLoads.values where !load.pinned && !load.task.isCancelled {
            load.task.cancel()
            cancelled = true
        }
        if cancelled { wakeHostsForLocalArrival() }
    }

    /// A newer viewport replaces the queue. Running loads (at most `maxLocalLoads`) always finish: several
    /// grids share this feed, and cancelling on every replace would let one grid stop another grid's
    /// downloads without a wake.
    private func submitLocalDemand(_ demand: [(uid: PhotoUID, pixels: Int)], replacing: Bool) {
        if replacing {
            localDemand = demand
        } else {
            let queued = Set(localDemand.map(\.uid))
            localDemand.append(contentsOf: demand.filter { !queued.contains($0.uid) })
        }
        pumpLocalLoads()
    }

    private func pumpLocalLoads() {
        guard ownerLeaseIsCurrent() else { return }
        guard let localLoader else {
            for request in localDemand where localAuthorization.isAllowed(request.uid) {
                unfetchable.insert(request.uid)
            }
            localDemand.removeAll()
            return
        }
        // Demand behind a running load stays queued: if that load was cancelled, the photo starts again once
        // it finishes, so a quick scroll away and back never leaves a blank tile.
        var remaining: [(uid: PhotoUID, pixels: Int)] = []
        for request in localDemand {
            if localLoads[request.uid] != nil {
                remaining.append(request)
            } else if localLoads.count < Self.maxLocalLoads {
                guard shouldLoadLocal(request.uid, pixels: request.pixels) else { continue }
                startLocalLoad(request.uid, pixels: request.pixels, loader: localLoader, pinned: false)
            } else {
                remaining.append(request)
            }
        }
        localDemand = remaining
    }

    private func shouldLoadLocal(_ uid: PhotoUID, pixels: Int) -> Bool {
        localAuthorization.isAllowed(uid) && !unfetchable.contains(uid) && localLoads[uid] == nil
            && !decoded.hasAdequateEntry(for: uid, requestedPixels: max(1, pixels))
    }

    /// Loads one local photo at `pixels`. The attempted size becomes the decode cap, so a smaller device
    /// source never keeps a visible tile asking for an upgrade.
    @discardableResult
    private func startLocalLoad(
        _ uid: PhotoUID,
        pixels: Int,
        loader: any LocalThumbnailLoading,
        pinned: Bool
    ) -> Task<Void, Never> {
        let id = UUID()
        let pixels = max(1, pixels)
        let task = Task { [weak self] in
            let image = await loader.thumbnails(for: [uid], maxPixelSize: CGFloat(pixels))[uid]
            let cancelled = Task.isCancelled
            await self?.finishLocalLoad(uid, id: id, pixels: pixels, image: image, cancelled: cancelled)
        }
        localLoads[uid] = (id, pinned, task)
        return task
    }

    private func finishLocalLoad(_ uid: PhotoUID, id: UUID, pixels: Int, image: DecodedThumbnail?, cancelled: Bool) {
        guard localLoads[uid]?.id == id else { return }
        localLoads[uid] = nil
        defer { pumpLocalLoads() }
        guard !cancelled, ownerLeaseIsCurrent(), localAuthorization.isAllowed(uid) else { return }
        guard let image else {
            noteLocalFailure(uid)
            return
        }
        localFailedAttempts[uid] = nil
        guard storeDecoded(image, for: uid, decodePixelCap: pixels) != nil else { return }
        cacheArrivalWake.call()
        // An iCloud download can outlast the host wake window; the grid must still learn about the image.
        wakeHostsForLocalArrival()
    }

    private func wakeHostsForLocalArrival() {
        visibleDiskDemandInbox.invalidate()
        imagesAvailableWake.call()
    }

    private func noteLocalFailure(_ uid: PhotoUID) {
        let attempts = (localFailedAttempts[uid] ?? 0) + 1
        localFailedAttempts[uid] = attempts
        let delay = min(600, 30 << min(attempts - 1, 5))
        localRetryAt[uid] = .now + .seconds(delay)
        unfetchable.insert(uid)
        scheduleLocalRetry()
    }

    private func scheduleLocalRetry() {
        guard let due = localRetryAt.values.min() else { return }
        if let scheduled = localRetryTask {
            guard due < scheduled.due else { return }
            scheduled.task.cancel()
        }
        let task = Task { [weak self] in
            try? await Task.sleep(until: due, clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.releaseDueLocalRetries()
        }
        localRetryTask = (due, task)
    }

    /// Lets failed local photos load again once their delay passed. Visible grids ask for them on the wake.
    private func releaseDueLocalRetries() {
        localRetryTask = nil
        let now = ContinuousClock.now
        let due = localRetryAt.filter { $0.value <= now }.map(\.key)
        for uid in due {
            localRetryAt[uid] = nil
            unfetchable.remove(uid)
        }
        // The first retry comes after the host wake window can close; wake directly so an idle grid asks for
        // its visible tiles again. At most once per retry deadline.
        if !due.isEmpty { wakeHostsForLocalArrival() }
        scheduleLocalRetry()
    }

    private func noteDeniedLocalDemand(_ requests: ArraySlice<ThumbnailRequest>) {
        for request in requests where request.uid.isLocalPending && !readAllowed(request.uid) {
            if deniedLocalDemand.count >= Self.maxDeniedLocalDemand { deniedLocalDemand.removeAll() }
            deniedLocalDemand[request.uid] = Int(effectiveDecodePixels(for: request))
        }
    }

    /// Publishes a batch arrival that could not reach the disk cache because the device is nearly full.
    private func publishMemoryOnlyArrival(
        _ image: DecodedThumbnail,
        for uid: PhotoUID,
        writerGeneration: CacheWriterGeneration.Token
    ) -> Bool {
        guard cache.isCurrentWriterGeneration(writerGeneration),
            storeDecoded(image, for: uid, decodePixelCap: Int(configuration.targetPixels)) != nil
        else { return false }
        notifyHostOfAvailableImageIfVisible()
        return true
    }

    /// A completed disk decode is immediately useful to the Metal grid. This wake intentionally happens at each
    /// completion, rather than after the surrounding task group drains: the native host coalesces redraw requests
    /// onto its display link, so the first ready visible tile can be uploaded while slower encrypted reads run.
    private func notifyHostOfAvailableImageIfVisible() {
        visibleDiskDemandInbox.invalidate()
        guard hostArrivalWakeIsLive(now: clock()) else { return }
        imagesAvailableWake.call()
    }

    private func recordError(_ message: String) {
        lastErrors.append(message)
        if lastErrors.count > 10 { lastErrors.removeFirst(lastErrors.count - 10) }
    }

    private func emitPrefetchSummary() {
        #if DEBUG
            let pausedReason: String
            if !prefetchEnabled {
                pausedReason = "disabled"
            } else if prefetchPaused {
                pausedReason = "manual"
            } else {
                pausedReason = "none"
            }
            let now = clock()
            let queueDepth = priority.count + max(0, sequential.count - sequentialIndex)
            let isActive = queueDepth > 0 || downloadInFlight + decodeInFlight > 0
            let intervalElapsed = lastPrefetchSummaryAt.map { now.timeIntervalSince($0) >= 1 } ?? true
            let shouldEmit =
                intervalElapsed
                || (lastPrefetchSummaryWasActive && !isActive)
                || lastPrefetchSummaryPausedReason != pausedReason
            guard shouldEmit else { return }
            lastPrefetchSummaryAt = now
            lastPrefetchSummaryWasActive = isActive
            lastPrefetchSummaryPausedReason = pausedReason
            diagnostics.emit(
                "ThumbPrefetch",
                [
                    "enabled": "\(prefetchEnabled)",
                    "queueDepth": "\(queueDepth)",
                    "activeJobs": "\(downloadInFlight + decodeInFlight)",
                    "completed": "\(prefetchCompleted)",
                    "failed": "\(prefetchFailed)",
                    "failedTimeout": "\(prefetchFailedTimeout)",
                    "failedBatchError": "\(prefetchFailedBatchError)",
                    "failedItemError": "\(prefetchFailedItemError)",
                    "failedUnreported": "\(prefetchFailedUnreported)",
                    "failedWithheld": "\(prefetchFailedWithheld)",
                    "unfetchable": "\(unfetchable.count)",
                    "skippedUnfetchable": "\(skippedUnfetchable)",
                    "diskHit": "\(prefetchDiskHit)",
                    "downloadStarted": "\(prefetchDownloadStarted)",
                    "downloadCompleted": "\(prefetchDownloadCompleted)",
                    "decodeStarted": "\(prefetchDecodeStarted)",
                    "decodeCompleted": "\(prefetchDecodeCompleted)",
                    "pausedReason": pausedReason,
                    "lastError": lastErrors.last ?? "-",
                ])
        #endif
    }

    private static func key(_ uid: PhotoUID) -> NSString {
        "\(uid.volumeID)~\(uid.nodeID)" as NSString
    }
}

#if DEBUG
    private final class ThumbnailFeedCoreTestingHooks: @unchecked Sendable {
        private let lock = NSLock()
        private var diskProbeHook: (@Sendable () -> Void)?
        private var workersStoppedHook: (@Sendable () -> Void)?
        private var permitWaitHook: (@Sendable () -> Void)?
        private var coverageStepHook: (@Sendable () -> Void)?

        func setAfterWindowPermitWait(_ hook: (@Sendable () -> Void)?) {
            lock.withLock { permitWaitHook = hook }
        }

        func afterWindowPermitWait() {
            let hook = lock.withLock { permitWaitHook }
            hook?()
        }

        func setBeforeCoverageScanStep(_ hook: (@Sendable () -> Void)?) {
            lock.withLock { coverageStepHook = hook }
        }

        func beforeCoverageScanStep() {
            let hook = lock.withLock { coverageStepHook }
            hook?()
        }

        func setBeforeDiskProbe(_ hook: (@Sendable () -> Void)?) {
            lock.withLock { diskProbeHook = hook }
        }

        func setBeforeWorkersStopped(_ hook: (@Sendable () -> Void)?) {
            lock.withLock { workersStoppedHook = hook }
        }

        func beforeWorkersStopped() {
            let hook = lock.withLock { workersStoppedHook }
            hook?()
        }

        func beforeDiskProbe() {
            let hook = lock.withLock { diskProbeHook }
            hook?()
        }
    }

    extension ThumbnailFeedCore {
        /// Debug-only seam for installing a synchronous gate before a disk probe starts.
        nonisolated func setDiskProbeHookForTesting(_ hook: (@Sendable () -> Void)?) {
            testingHooks.setBeforeDiskProbe(hook)
        }

        /// Debug-only seam that runs one bounded end-of-crawl coverage-scan step and returns its probe count.
        func coverageScanStepStatCountForTesting(seeding uids: [PhotoUID]) async -> Int {
            sequential = uids
            coverageScanCursor = 0
            _ = await advanceDiskCoverageScan()
            // The cursor advances by one bounded chunk per call and reports that step's probe count.
            return coverageScanCursor
        }

        /// Debug-only seam for a synchronous gate after a worker's wait for the window permit ended.
        nonisolated func setWindowPermitWaitHookForTesting(_ hook: (@Sendable () -> Void)?) {
            testingHooks.setAfterWindowPermitWait(hook)
        }

        /// Debug-only seam for a synchronous gate before each coverage scan step.
        nonisolated func setCoverageScanStepHookForTesting(_ hook: (@Sendable () -> Void)?) {
            testingHooks.setBeforeCoverageScanStep(hook)
        }

        /// Debug-only seam that runs the end-of-crawl coverage refresh over `uids` and names its outcome.
        func runCoverageRefreshForTesting(seeding uids: [PhotoUID], shouldStop: @escaping () -> Bool) async -> String {
            sequential = uids
            coverageScanCursor = 0
            diskPresence.beginTracking(uids, reporting: Set(uids), knownPresent: [])
            return switch await runCoverageRefresh(shouldStop: shouldStop) {
            case .settled: "settled"
            case .recrawl: "recrawl"
            case .aborted: "aborted"
            }
        }

        /// Debug-only seam that reports end-of-crawl coverage refreshes started during this crawl.
        func coverageRefreshStartCountForTesting() -> Int { coverageRefreshStarts }

        /// Debug-only seam for a synchronous gate after the last worker returned and before the feed records the stop.
        nonisolated func setWorkersStoppedHookForTesting(_ hook: (@Sendable () -> Void)?) {
            testingHooks.setBeforeWorkersStopped(hook)
        }

        /// Debug-only seam that reports whether a held crawl still waits for its wake.
        func crawlWakePendingForTesting() -> Bool { crawlWakeTask != nil }

        /// Debug-only seam that reports how often the workers started.
        func workerStartCountForTesting() -> Int { workerStarts }

        /// Debug-only seam that reports refreshes which ran a chunked `cache.has` sweep.
        func coverageFullScanCountForTesting() -> Int { coverageFullScans }

        func waitForRetiredWorkersForTesting() async {
            let tasks = retiredWorkerTasks
            for task in tasks { await task.value }
        }

        func setDownloadSlotWaitHookForTesting(_ hook: (@Sendable () -> Void)?) {
            downloadSlotWaitHookForTesting = hook
        }

        /// Debug-only seam that runs when the crawl's wait for the permit returns, before the checks after it.
        func setWindowPermitReturnHookForTesting(_ hook: (@Sendable () async -> Void)?) {
            windowPermitReturnHookForTesting = hook
        }

        /// Debug-only seam that reports the download counters and whether any worker task still runs.
        func downloadCountersForTesting() -> (activeDownloaders: Int, downloadInFlight: Int, workersRunning: Bool) {
            (activeDownloaders, downloadInFlight, workersRunning)
        }
    }
#endif

/// The moving viewport has one replaceable queue and a fixed worker population. Pending work from an older
/// generation disappears immediately; active work is never duplicated or awaited as a viewport-wide barrier.
struct LatestVisibleDecodeDemand {
    struct Job: Hashable, Sendable {
        let uid: PhotoUID
        let maxPixels: CGFloat
        let isUpgrade: Bool
    }

    private(set) var generation: UInt64 = 0
    private var pending: [Job] = []
    private var active: [PhotoUID: Job] = [:]
    private var desired: [PhotoUID: Job] = [:]

    var pendingCount: Int { pending.count }
    var activeCount: Int { active.count }

    mutating func cancelAll() {
        pending.removeAll(keepingCapacity: false)
        active.removeAll(keepingCapacity: false)
        desired.removeAll(keepingCapacity: false)
    }

    mutating func replace(with jobs: [Job], generation newGeneration: UInt64) -> Bool {
        guard newGeneration >= generation else { return false }
        generation = newGeneration
        var seen = Set<PhotoUID>()
        let uniqueJobs = jobs.filter { job in
            guard seen.insert(job.uid).inserted else { return false }
            return true
        }
        desired = Dictionary(uniqueKeysWithValues: uniqueJobs.map { ($0.uid, $0) })
        // Never run two synchronous reads/decrypts/decodes for the same asset. If the latest viewport asks for
        // a sharper tile while a smaller decode is active, `complete` queues the upgrade after that result has
        // been published.
        pending = uniqueJobs.filter { active[$0.uid] == nil }
        return true
    }

    mutating func takeNext() -> Job? {
        guard !pending.isEmpty else { return nil }
        let job = pending.removeFirst()
        active[job.uid] = job
        return job
    }

    mutating func complete(_ job: Job) {
        guard active[job.uid] == job else { return }
        active.removeValue(forKey: job.uid)
        guard let latest = desired[job.uid], latest.maxPixels > job.maxPixels else { return }
        guard !pending.contains(where: { $0.uid == job.uid }) else { return }
        pending.append(Job(uid: latest.uid, maxPixels: latest.maxPixels, isUpgrade: true))
    }

    mutating func returnToPending(_ job: Job) {
        guard active[job.uid] == job else { return }
        active.removeValue(forKey: job.uid)
        guard let latest = desired[job.uid] else { return }
        guard !pending.contains(where: { $0.uid == job.uid }) else { return }
        pending.insert(latest, at: 0)
    }
}

/// Thread-safe single-consumer mailbox for high-frequency viewport updates. A submitter schedules an actor
/// drain only when none is active; the drain always takes the newest generation and discards superseded values.
final class LatestVisibleDecodeDemandInbox: @unchecked Sendable {
    struct Submission: Sendable, Equatable {
        let requests: [ThumbnailRequest]
        let generation: UInt64
        /// A replay after a Proton arrival, not a fresh viewport from a host.
        var isReplay = false
    }

    private let lock = NSLock()
    private var latest: Submission?
    private var retainedRequests: [ThumbnailRequest]?
    private var needsResubmission = false
    private var drainScheduled = false
    private var nextGeneration: UInt64 = 0

    /// Returns true only for the producer that must schedule the single drain task. The mailbox owns the
    /// generation so replacing a platform data source cannot reset ordering while this feed remains alive.
    func submit(requests: [ThumbnailRequest]) -> Bool {
        lock.withLock {
            guard needsResubmission || requests != retainedRequests else { return false }
            retainedRequests = requests
            return enqueue(requests)
        }
    }

    /// A scope admission or disk arrival can make an unchanged viewport actionable. Re-submit the latest
    /// intent under the same lock so recovery cannot overwrite a newer viewport with an older snapshot.
    func replay() -> Bool {
        lock.withLock {
            guard let retainedRequests, !retainedRequests.isEmpty else { return false }
            // A fresh viewport that is not drained yet carries the same requests and also its local demand.
            if let latest, !latest.isReplay { return false }
            return enqueue(retainedRequests, isReplay: true)
        }
    }

    /// Terminal owner shutdown clears intent; source reconciliation only pauses execution and retains it.
    func cancel() {
        lock.withLock {
            retainedRequests = nil
            latest = nil
            needsResubmission = false
        }
    }

    func invalidate() {
        lock.withLock { needsResubmission = true }
    }

    private func enqueue(_ requests: [ThumbnailRequest], isReplay: Bool = false) -> Bool {
        // A replay skips local demand, so the host's next identical viewport must still get through.
        if !isReplay { needsResubmission = false }
        nextGeneration &+= 1
        latest = Submission(requests: requests, generation: nextGeneration, isReplay: isReplay)
        guard !drainScheduled else { return false }
        drainScheduled = true
        return true
    }

    /// Returns the newest pending value. When empty, atomically releases drain ownership so a racing producer
    /// either observes an active drain or becomes responsible for scheduling the next one.
    func takeLatestOrFinish() -> Submission? {
        lock.withLock {
            guard let submission = latest else {
                drainScheduled = false
                return nil
            }
            latest = nil
            return submission
        }
    }
}

/// Tracks callback writes so a completed loader batch does not report delivery before its encrypted disk writes
/// finish on the dedicated executor. A callback submitted after the loader closes is discarded, so no write can
/// outlive the task group and escape owner teardown.
private final class ThumbnailWriteTaskGroup: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var closed = false

    func submit(_ operation: @escaping @Sendable () async -> Void) {
        lock.withLock {
            guard !closed else { return }
            tasks.append(Task { await operation() })
        }
    }

    func finishAndWait() async {
        let pending = lock.withLock {
            closed = true
            let pending = tasks
            tasks.removeAll(keepingCapacity: false)
            return pending
        }
        for task in pending {
            await task.value
        }
    }
}

/// Foundation file reads, CryptoKit and ImageIO are synchronous. Running them directly in Swift child tasks can
/// occupy the cooperative executor until unrelated actor work stops progressing. A dedicated concurrent queue
/// contains that blocking boundary; `DecodePermitPool` remains the feed-wide concurrency cap.
final class ThumbnailDecodeWorkExecutor: @unchecked Sendable {
    private let interactiveQueue = DispatchQueue(
        label: "at.oncloud.encryptedmemories.thumbnail-decode.interactive",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let backgroundQueue = DispatchQueue(
        label: "at.oncloud.encryptedmemories.thumbnail-decode.background",
        qos: .utility,
        attributes: .concurrent
    )

    func perform<T: Sendable>(
        priority: ThumbnailPriority,
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        let queue = priority <= .zoomAnchorAndFocusRow ? interactiveQueue : backgroundQueue
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }
}

/// Cancellation-safe, priority-aware admission for the feed's decrypt/decode lanes. Visible work jumps queued
/// background work; an already-running synchronous operation retains its permit until the dedicated queue returns.
actor DecodePermitPool {
    private struct Waiter {
        let id: UUID
        let priority: ThumbnailPriority
        let sequence: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var available: Int
    private var waiters: [Waiter] = []
    private var nextSequence: UInt64 = 0

    init(permits: Int) {
        available = max(1, permits)
    }

    func acquire(priority: ThumbnailPriority) async -> Bool {
        guard !Task.isCancelled else { return false }
        if available > 0 {
            available -= 1
            return true
        }

        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(
                        Waiter(
                            id: waiterID,
                            priority: priority,
                            sequence: nextSequence,
                            continuation: continuation
                        ))
                    nextSequence &+= 1
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }

        // A cancellation can race the handoff from `release()`. Do not strand the permit in that case.
        if acquired, Task.isCancelled {
            release()
            return false
        }
        return acquired
    }

    func release() {
        guard !waiters.isEmpty else {
            available += 1
            return
        }
        let index = waiters.indices.min { lhs, rhs in
            let left = waiters[lhs]
            let right = waiters[rhs]
            if left.priority != right.priority { return left.priority < right.priority }
            return left.sequence < right.sequence
        }!
        waiters.remove(at: index).continuation.resume(returning: true)
    }

    private func cancel(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

/// Photos whose thumbnail was refused. A refusal holds until the next fresh crawl, except for a photo that joined
/// the membership moments ago: its refusal lapses after a short delay, a bounded number of times.
private final class UnfetchableThumbnailBox: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: @Sendable () -> Date
    private var ids: Set<PhotoUID> = []
    /// When a held refusal lapses. A lapsed entry stays in `ids` until the next refusal or clear, but no read sees it.
    private var lapseAt: [PhotoUID: Date] = [:]
    /// Photos that joined within `recentJoinRefusalWindow`, and how often their refusal lapsed since. A crawl
    /// clear keeps both, so the bound holds per join and not per crawl.
    private var joinedAt: [PhotoUID: Date] = [:]
    private var lapses: [PhotoUID: Int] = [:]

    init(clock: @escaping @Sendable () -> Date) {
        self.clock = clock
    }

    var count: Int {
        count(intersecting: nil)
    }

    func count(intersecting allowed: Set<PhotoUID>?) -> Int {
        let now = clock()
        return lock.withLock {
            let held = lapseAt.isEmpty ? ids : ids.filter { lapseAt[$0].map { now < $0 } ?? true }
            guard let allowed else { return held.count }
            return held.intersection(allowed).count
        }
    }

    func contains(_ uid: PhotoUID) -> Bool {
        let entry = lock.withLock { (held: ids.contains(uid), lapse: lapseAt[uid]) }
        guard entry.held else { return false }
        guard let lapse = entry.lapse else { return true }
        return clock() < lapse
    }

    /// Returns when the refusal lapses, or nil when it holds until the next fresh crawl.
    @discardableResult
    func insert(_ uid: PhotoUID) -> Date? {
        let now = clock()
        return lock.withLock { hold(uid, now: now) }
    }

    /// Returns the earliest lapse among the refused photos, or nil when every refusal holds.
    @discardableResult
    func formUnion<S: Sequence>(_ sequence: S) -> Date? where S.Element == PhotoUID {
        let now = clock()
        return lock.withLock {
            sequence.reduce(nil as Date?) { earliest, uid in
                guard let lapse = hold(uid, now: now) else { return earliest }
                return min(earliest ?? lapse, lapse)
            }
        }
    }

    func subtract<S: Sequence>(_ sequence: S) where S.Element == PhotoUID {
        lock.withLock {
            for uid in sequence {
                ids.remove(uid)
                lapseAt[uid] = nil
            }
        }
    }

    func remove(_ uid: PhotoUID) {
        lock.withLock {
            ids.remove(uid)
            lapseAt[uid] = nil
        }
    }

    func removeAll() {
        lock.withLock {
            ids.removeAll(keepingCapacity: true)
            lapseAt.removeAll(keepingCapacity: true)
        }
    }

    /// Records photos that joined the membership now. Joins older than the window are forgotten.
    func noteJoined<S: Sequence>(_ uids: S) where S.Element == PhotoUID {
        let now = clock()
        lock.withLock {
            let window = ThumbnailFeedCore.recentJoinRefusalWindow
            for uid in joinedAt.filter({ now.timeIntervalSince($0.value) >= window }).keys {
                joinedAt[uid] = nil
                lapses[uid] = nil
            }
            for uid in uids where joinedAt[uid] == nil {
                joinedAt[uid] = now
            }
        }
    }

    /// The first lapse after `date`. Each lapse wakes the hosts at most once.
    func nextLapse(after date: Date) -> Date? {
        lock.withLock { lapseAt.values.filter { $0 > date }.min() }
    }

    private func hold(_ uid: PhotoUID, now: Date) -> Date? {
        ids.insert(uid)
        lapseAt[uid] = nil
        guard let joined = joinedAt[uid],
            now.timeIntervalSince(joined) < ThumbnailFeedCore.recentJoinRefusalWindow
        else { return nil }
        let used = lapses[uid, default: 0]
        guard used < ThumbnailFeedCore.maxRecentJoinRefusalLapses else { return nil }
        lapses[uid] = used + 1
        let lapse = now.addingTimeInterval(ThumbnailFeedCore.recentJoinRefusalLapse)
        lapseAt[uid] = lapse
        return lapse
    }
}

private struct DecodedTile: @unchecked Sendable {
    let uid: PhotoUID
    let decoded: DecodedThumbnail?
    let diskHadData: Bool
    let readDurationMs: Double
    let durationMs: Double
    let decodePixelCap: Int
    let isUpgrade: Bool
}

private final class ByteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?

    func set(_ data: Data) {
        lock.withLock { bytes = data }
    }

    var value: Data? {
        lock.withLock { bytes }
    }
}

private final class UIDSetBox: @unchecked Sendable {
    private let lock = NSLock()
    private var uids: Set<PhotoUID> = []

    func insert(_ uid: PhotoUID) {
        lock.withLock { _ = uids.insert(uid) }
    }

    var snapshot: Set<PhotoUID> {
        lock.withLock { uids }
    }
}

/// One-shot continuation used to resolve completion, timeout, and cancellation races exactly once.
private final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var resolvedValue: Value?

    /// Installs the waiter. A cancellation can resolve before installation, in which case this
    /// method resumes the waiter immediately and tells the caller not to start race tasks.
    func install(_ continuation: CheckedContinuation<Value, Never>) -> Bool {
        let pending = lock.withLock { () -> Value? in
            guard let resolvedValue else {
                self.continuation = continuation
                return nil
            }
            return resolvedValue
        }
        guard let pending else { return true }
        continuation.resume(returning: pending)
        return false
    }

    @discardableResult
    func resolve(_ value: Value) -> Bool {
        let result = lock.withLock { () -> (claimed: Bool, continuation: CheckedContinuation<Value, Never>?) in
            guard resolvedValue == nil else { return (false, nil) }
            resolvedValue = value
            defer { continuation = nil }
            return (true, continuation)
        }
        result.continuation?.resume(returning: value)
        return result.claimed
    }
}

/// Lock-guarded last-visible-demand timestamp, shared between the actor's methods and the `nonisolated`
/// crawl reads. Lets `noteVisibleDemand` record demand without an actor hop (so it can't starve behind the
/// crawl it is meant to pause).
private final class LastDemandBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date?

    func set(_ date: Date) {
        lock.withLock { value = date }
    }

    func get() -> Date? {
        lock.withLock { value }
    }
}

/// Identity of one platform grid host that reports its own gesture state to a shared thumbnail feed.
///
/// A host creates one owner for its lifetime and passes it with every interaction report. Owners are only
/// compared for identity; the feed never keeps a reference to the host itself.
public struct ThumbnailInteractionOwner: Hashable, Sendable {
    private let id = UUID()

    public init() {}
}

/// Lock-guarded gesture state shared with synchronous background-work governors. Platform hosts
/// update it only at interaction boundaries, so an idle viewport never generates polling or writes.
/// Contributions are keyed by owner so one grid stopping cannot clear another grid's live gesture.
private final class InteractionStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var activeOwners: Set<ThumbnailInteractionOwner> = []

    func set(_ active: Bool, owner: ThumbnailInteractionOwner) {
        lock.withLock {
            if active {
                activeOwners.insert(owner)
            } else {
                activeOwners.remove(owner)
            }
        }
    }

    func hasActiveOwners() -> Bool {
        lock.withLock { !activeOwners.isEmpty }
    }

    func activeOwnerCount() -> Int {
        lock.withLock { activeOwners.count }
    }
}

/// Synchronous registration closes the first-viewport race where tiny cached images could finish before a
/// fire-and-forget actor task installed the host wake. Invocation copies all callbacks under lock and calls them
/// outside the critical section, so observers may safely end or add registrations while a wake is in flight.
private final class ImagesAvailableWakeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [UUID: @Sendable () -> Void] = [:]

    func add(_ callback: @escaping @Sendable () -> Void) -> ThumbnailFeedWakeRegistration {
        let id = UUID()
        lock.withLock { callbacks[id] = callback }
        return ThumbnailFeedWakeRegistration { [weak self] in
            self?.remove(id)
        }
    }

    private func remove(_ id: UUID) {
        _ = lock.withLock { callbacks.removeValue(forKey: id) }
    }

    func call() {
        let current: [@Sendable () -> Void] = lock.withLock { Array(callbacks.values) }
        for callback in current { callback() }
    }
}

extension ThumbnailFeedCore {
    private static let visibleRetryFirstDelay: Duration = .seconds(1)
    private static let visibleRetryLongestDelay: Duration = .seconds(16)

    /// Loads one thumbnail for a view that is on screen into the decoded tier, and keeps trying until it exists.
    ///
    /// A single request can return no image while the bytes are still on the way. This asks with visible priority,
    /// then waits for the arrival wake or a bounded backoff, whichever comes first, and asks again. It returns nil
    /// for a photo that has no thumbnail, and ends when the caller's task is cancelled, for example when the view
    /// leaves the screen. Every platform loads its on-screen thumbnails through this one loop.
    public nonisolated func visibleDecoded(
        for uid: PhotoUID, access: VisibleThumbnailAccess? = nil
    ) async -> DecodedThumbnail? {
        var delay = Self.visibleRetryFirstDelay
        while !Task.isCancelled {
            if let access, !readAllowed(uid, access: access) { return nil }
            // The wait starts before the request, so an arrival during the request already ends it.
            let pause = delay
            let wait = Task<Void, Never> { try? await Task.sleep(for: pause) }
            let registration = setOnCacheArrivalWake { wait.cancel() }
            defer { registration.end() }
            // Scoped tiles own a direct flight. The grid's replaceable priority queue cannot displace it.
            if access == nil { _ = await requestPriority(uid, priority: .visibleNow) }
            if let image = await decoded(for: uid, access: access) {
                wait.cancel()
                return image
            }
            // The feed proved that this photo has no thumbnail. Another request cannot change that.
            if isKnownUnfetchable(uid, access: access) {
                wait.cancel()
                return nil
            }
            await withTaskCancellationHandler {
                _ = await wait.value
            } onCancel: {
                wait.cancel()
            }
            delay = min(delay * 2, Self.visibleRetryLongestDelay)
        }
        return nil
    }
}
