import CoreGraphics
import Foundation
import OSLog

/// Bounded timestamp ledger shared by every diagnostics throttle path.
///
/// Dynamic diagnostic fields can contain short-lived request or route identities. Retaining one dictionary
/// entry per identity for the process lifetime makes diagnostics memory grow with user activity. The ledger
/// keeps the same throttle semantics while capping retention. Eviction is paid only when a new key reaches
/// the small fixed ceiling, so the normal repeated-key path remains one dictionary lookup.
struct BoundedDiagnosticsThrottle: Sendable {
    static let defaultCapacity = 512

    private let capacity: Int
    private var lastEmission: [String: Date] = [:]

    init(capacity: Int = defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    var count: Int { lastEmission.count }

    mutating func shouldEmit(key: String, now: Date, interval: TimeInterval) -> Bool {
        if let last = lastEmission[key], now.timeIntervalSince(last) < interval {
            return false
        }
        if lastEmission[key] == nil, lastEmission.count >= capacity,
            let oldest = lastEmission.min(by: { $0.value < $1.value })?.key
        {
            lastEmission.removeValue(forKey: oldest)
        }
        lastEmission[key] = now
        return true
    }

    mutating func removeAll() {
        lastEmission.removeAll(keepingCapacity: false)
    }
}

public enum ThumbnailPriority: Int, CaseIterable, Codable, Sendable, Comparable {
    case visibleNow = 0
    case zoomAnchorAndFocusRow = 1
    case likelyZoomOutTargetCoverage = 2
    case nearViewportScrollAhead = 3
    case idleLibraryCrawl = 4

    public static func < (lhs: ThumbnailPriority, rhs: ThumbnailPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ThumbnailRequest: Hashable, Codable, Sendable {
    public let uid: PhotoUID
    /// Requested decode/upload pixel side. `0` (the default) means "no size opinion - use the feed's
    /// configured target". A positive value can only raise the decode above that target (level-aware
    /// hosts ask big for big tiles); it never shrinks the shared RAM image below it.
    public let pixelSize: Int
    public let lod: Int
    public let cropMode: String

    public init(uid: PhotoUID, pixelSize: Int = 0, lod: Int = 0, cropMode: String = "default") {
        self.uid = uid
        self.pixelSize = pixelSize
        self.lod = lod
        self.cropMode = cropMode
    }
}

public struct ThumbnailCacheTierState: Equatable, Sendable {
    public let knownInTimeline: Bool
    public let diskThumbnail: Bool
    public let ramDecoded: Bool
    public let gpuTexture: Bool

    public init(
        knownInTimeline: Bool,
        diskThumbnail: Bool,
        ramDecoded: Bool,
        gpuTexture: Bool
    ) {
        self.knownInTimeline = knownInTimeline
        self.diskThumbnail = diskThumbnail
        self.ramDecoded = ramDecoded
        self.gpuTexture = gpuTexture
    }
}

public struct WarmDecodedResult: Equatable, Sendable {
    public let requested: Int
    public let alreadyDecoded: Int
    public let decodedFromDisk: Int
    public let queuedNetwork: Int
    public let missing: Int
    public let mainThreadDecodeCount: Int

    public init(
        requested: Int,
        alreadyDecoded: Int,
        decodedFromDisk: Int,
        queuedNetwork: Int,
        missing: Int,
        mainThreadDecodeCount: Int = 0
    ) {
        self.requested = requested
        self.alreadyDecoded = alreadyDecoded
        self.decodedFromDisk = decodedFromDisk
        self.queuedNetwork = queuedNetwork
        self.missing = missing
        self.mainThreadDecodeCount = mainThreadDecodeCount
    }
}

public enum ThumbnailVisualState: String, CaseIterable, Codable, Sendable {
    case realImageDrawn
    case placeholderDrawn
    case diskMissing
    case diskHitRamMissing
    case ramHitGpuMissing
    case atlasMissing
    case geometryHole
    case intentionallyClipped
    case unknownBug
}

public struct ThumbnailVisualClassification: Sendable, Equatable {
    public let uid: PhotoUID?
    public let rect: CGRect
    public let state: ThumbnailVisualState
    public let phase: String
    public let context: String

    public init(
        uid: PhotoUID?,
        rect: CGRect,
        state: ThumbnailVisualState,
        phase: String,
        context: String = ""
    ) {
        self.uid = uid
        self.rect = rect
        self.state = state
        self.phase = phase
        self.context = context
    }
}

public struct ThumbnailHealthCounters: Sendable, Equatable {
    public var visibleCount = 0
    public var realImageDrawn = 0
    public var placeholderDrawn = 0
    public var diskMissing = 0
    public var diskHitRamMissing = 0
    public var ramHitGpuMissing = 0
    public var atlasMissing = 0
    public var geometryHole = 0
    public var intentionallyClipped = 0
    public var unknownBug = 0

    public init() {}

    public mutating func record(_ state: ThumbnailVisualState) {
        visibleCount += 1
        switch state {
        case .realImageDrawn: realImageDrawn += 1
        case .placeholderDrawn: placeholderDrawn += 1
        case .diskMissing: diskMissing += 1
        case .diskHitRamMissing: diskHitRamMissing += 1
        case .ramHitGpuMissing: ramHitGpuMissing += 1
        case .atlasMissing: atlasMissing += 1
        case .geometryHole: geometryHole += 1
        case .intentionallyClipped: intentionallyClipped += 1
        case .unknownBug: unknownBug += 1
        }
    }
}

public struct GridZoomHotPathCounters: Sendable, Equatable {
    public var dbQueryDuringPinch = 0
    public var diskReadDuringPinch = 0
    /// Cheap `cache.has(_)` existence probes during a pinch - not actual byte reads. Split out from
    /// `diskReadDuringPinch` so the "disk read" stat reflects real `diskData(_)` reads only.
    public var diskPresenceCheckDuringPinch = 0
    public var decodeDuringPinch = 0
    public var networkRequestDuringPinch = 0

    public init() {}
}

public struct ThumbnailDecodeStats: Sendable, Equatable {
    public var diskCacheHit = 0
    public var diskCacheMiss = 0
    public var ramDecodeHit = 0
    public var ramDecodeMiss = 0
    public var ramDecodeStarted = 0
    public var ramDecodeCompleted = 0
    public var ramDecodeFailed = 0
    public var ramDecodeQueueDepth = 0
    public var ramDecodeAverageMs: Double = 0
    public var ramDecodeP95Ms: Double = 0

    public init() {}
}

public struct DBQueryMetric: Sendable, Equatable {
    public let queryName: String
    public let durationMs: Double
    public let rowsReturned: Int
    public let ranOnMainThread: Bool
    public let duringActivePinch: Bool
    public let timestamp: Date

    public init(
        queryName: String,
        durationMs: Double,
        rowsReturned: Int,
        ranOnMainThread: Bool,
        duringActivePinch: Bool,
        timestamp: Date = Date()
    ) {
        self.queryName = queryName
        self.durationMs = durationMs
        self.rowsReturned = rowsReturned
        self.ranOnMainThread = ranOnMainThread
        self.duringActivePinch = duringActivePinch
        self.timestamp = timestamp
    }
}

public struct SupportDiagnosticEvent: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let category: String
    public let fields: [String: String]

    public init(timestamp: Date, category: String, fields: [String: String]) {
        self.timestamp = timestamp
        self.category = category
        self.fields = fields
    }
}

public struct PhotoDiagnosticsSupportSnapshot: Codable, Sendable, Equatable {
    public let counters: [String: Int]
    public let events: [SupportDiagnosticEvent]

    public init(counters: [String: Int], events: [SupportDiagnosticEvent]) {
        self.counters = counters
        self.events = events
    }
}

public struct PhotoPerformanceSignposter: @unchecked Sendable {
    private let signposter: OSSignposter

    public init(category: String) {
        let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: category)
        self.signposter = OSSignposter(logger: logger)
    }

    @discardableResult
    public func interval<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        defer { signposter.endInterval(name, state) }
        return try work()
    }
}

public enum PhotoPerformanceSignposts {
    public static let database = PhotoPerformanceSignposter(category: "Database")
    public static let grid = PhotoPerformanceSignposter(category: "Grid")
    public static let mediaFeed = PhotoPerformanceSignposter(category: "MediaFeed")
    public static let viewer = PhotoPerformanceSignposter(category: "Viewer")
}

public final class PhotoDiagnostics: @unchecked Sendable {
    public static let shared = PhotoDiagnostics()
    public static let debugConsoleLogsUserDefaultsKey = "EncryptedMemoriesDebugConsoleLogs"
    public static let debugConsoleLogsEnvironmentKey = "ENCRYPTED_MEMORIES_DEBUG_CONSOLE_LOGS"

    /// Every exported counter is selected by its complete, code-owned key. `increment(_:)` remains
    /// useful for live diagnostics, but a future caller cannot accidentally export an asset-derived
    /// suffix merely by choosing a familiar prefix.
    private static let supportCounterKeys: Set<String> = [
        "backup.metadata.equalCoordinates",
        "duplicates.thumbnail.blankOver3Seconds",
        "metrickit.diagnosticPayloads",
        "metrickit.metricPayloads",
        "ml.suggestions.cacheReadFailed",
        "ml.suggestions.evidenceBatchFailed",
        "ml.suggestions.evidenceRetryExhausted",
        "ml.suggestions.persistenceRetryExhausted",
        "ml.suggestions.snapshotDecodeFailed",
        "ml.suggestions.snapshotPreparationFailed",
        "ml.suggestions.snapshotRestored",
        "ml.suggestions.snapshotWriteFailed",
        "ml.suggestions.snapshotWriteSuperseded",
        "perf.videoPrefetchDeduped",
        "perf.videoPrefetchScheduled",
        "thumb.decodedUpgrade",
        "thumb.directLoadOverlapsBatch",
        "thumb.diskCacheHit",
        "thumb.diskCacheMiss",
        "thumb.diskDecodeFailed",
        "thumb.priorityUpgrade",
        "thumb.ramDecodeCompleted",
        "thumb.ramDecodeFailed",
        "thumb.ramDecodeMiss",
        "thumb.ramDecodeStarted",
        "thumb.ramDecodedHit",
        "thumb.unfetchableShortCircuit",
        "timeline.refresh.applied",
        "timeline.refresh.snapshotHit",
        "timeline.refresh.unchangedSkip",
    ]

    private let lock = NSLock()
    private var activePinch = false
    private var dbQueries: [DBQueryMetric] = []
    private var counters: [String: Int] = [:]
    private var eventThrottle = BoundedDiagnosticsThrottle()
    private var supportEvents: [SupportDiagnosticEvent] = []
    private var thumbHealth = ThumbnailHealthCounters()
    private var hotPath = GridZoomHotPathCounters()
    private var decodeDurationsMs: [Double] = []
    private var decodeQueueDepth = 0
    private let debugConsoleLogsAreEnabled: Bool

    public convenience init() {
        let environment = ProcessInfo.processInfo.environment
        self.init(
            debugConsoleLogsEnabled: environment[Self.debugConsoleLogsEnvironmentKey] == "1"
                || UserDefaults.standard.bool(forKey: Self.debugConsoleLogsUserDefaultsKey)
        )
    }

    init(debugConsoleLogsEnabled: Bool) {
        debugConsoleLogsAreEnabled = debugConsoleLogsEnabled
    }

    public func setActivePinch(_ active: Bool) {
        lock.withLock {
            activePinch = active
        }
    }

    public func isActivePinch() -> Bool {
        lock.withLock { activePinch }
    }

    public func increment(_ key: String, by amount: Int = 1) {
        lock.withLock {
            counters[key, default: 0] += amount
        }
    }

    public func counter(_ key: String) -> Int {
        lock.withLock { counters[key, default: 0] }
    }

    public func resetForTests() {
        lock.withLock {
            activePinch = false
            dbQueries.removeAll()
            counters.removeAll()
            eventThrottle.removeAll()
            supportEvents.removeAll()
            thumbHealth = ThumbnailHealthCounters()
            hotPath = GridZoomHotPathCounters()
            decodeDurationsMs.removeAll()
            decodeQueueDepth = 0
        }
    }

    public func recordDBQuery(queryName: String, durationMs: Double, rowsReturned: Int) {
        let ranOnMain = Thread.isMainThread
        let duringPinch = isActivePinch()
        if duringPinch {
            lock.withLock { hotPath.dbQueryDuringPinch += 1 }
        }
        let metric = DBQueryMetric(
            queryName: queryName,
            durationMs: durationMs,
            rowsReturned: rowsReturned,
            ranOnMainThread: ranOnMain,
            duringActivePinch: duringPinch
        )
        lock.withLock {
            dbQueries.append(metric)
            if dbQueries.count > 500 {
                dbQueries.removeFirst(dbQueries.count - 500)
            }
        }
        if duringPinch || ranOnMain || durationMs > 5 {
            emit(
                "DBHealth",
                [
                    "query": queryName,
                    "durationMs": format(durationMs),
                    "rows": "\(rowsReturned)",
                    "main": "\(ranOnMain)",
                    "activePinch": "\(duringPinch)",
                ])
        }
    }

    public func classifyThumbnail(_ classification: ThumbnailVisualClassification) {
        lock.withLock {
            thumbHealth.record(classification.state)
        }
        switch classification.state {
        case .geometryHole, .unknownBug, .atlasMissing:
            emit(
                "ThumbHealth",
                [
                    "uid": classification.uid.map { "\($0.volumeID)~\($0.nodeID)" } ?? "none",
                    "rect": rectDescription(classification.rect),
                    "state": classification.state.rawValue,
                    "phase": classification.phase,
                    "context": classification.context,
                ], throttleSeconds: 0.10)
        default:
            break
        }
    }

    public func thumbHealthCounters(reset: Bool = false) -> ThumbnailHealthCounters {
        lock.withLock {
            let snapshot = thumbHealth
            if reset { thumbHealth = ThumbnailHealthCounters() }
            return snapshot
        }
    }

    public func recordDiskReadDuringPinch() {
        guard isActivePinch() else { return }
        lock.withLock { hotPath.diskReadDuringPinch += 1 }
    }

    /// Records a cheap on-disk *presence* check (`cache.has`), distinct from an actual byte read, so
    /// presence probes don't inflate the `diskReadDuringPinch` stat.
    public func recordDiskPresenceCheckDuringPinch() {
        guard isActivePinch() else { return }
        lock.withLock { hotPath.diskPresenceCheckDuringPinch += 1 }
    }

    public func recordNetworkRequestDuringPinch() {
        guard isActivePinch() else { return }
        lock.withLock { hotPath.networkRequestDuringPinch += 1 }
    }

    public func recordDecodeStarted(queueDepth: Int) {
        lock.withLock {
            counters["thumb.ramDecodeStarted", default: 0] += 1
            decodeQueueDepth = queueDepth
            if activePinch { hotPath.decodeDuringPinch += 1 }
        }
    }

    public func recordDecodeCompleted(durationMs: Double, queueDepth: Int) {
        lock.withLock {
            counters["thumb.ramDecodeCompleted", default: 0] += 1
            decodeQueueDepth = queueDepth
            decodeDurationsMs.append(durationMs)
            if decodeDurationsMs.count > 500 {
                decodeDurationsMs.removeFirst(decodeDurationsMs.count - 500)
            }
        }
    }

    public func recordDecodeFailed(queueDepth: Int) {
        lock.withLock {
            counters["thumb.ramDecodeFailed", default: 0] += 1
            decodeQueueDepth = queueDepth
        }
    }

    public func decodeStats() -> ThumbnailDecodeStats {
        lock.withLock {
            var stats = ThumbnailDecodeStats()
            stats.diskCacheHit = counters["thumb.diskCacheHit", default: 0]
            stats.diskCacheMiss = counters["thumb.diskCacheMiss", default: 0]
            stats.ramDecodeHit = counters["thumb.ramDecodedHit", default: 0]
            stats.ramDecodeMiss = counters["thumb.ramDecodeMiss", default: 0]
            stats.ramDecodeStarted = counters["thumb.ramDecodeStarted", default: 0]
            stats.ramDecodeCompleted = counters["thumb.ramDecodeCompleted", default: 0]
            stats.ramDecodeFailed =
                counters["thumb.ramDecodeFailed", default: 0] + counters["thumb.diskDecodeFailed", default: 0]
            stats.ramDecodeQueueDepth = decodeQueueDepth
            stats.ramDecodeAverageMs = average(decodeDurationsMs)
            stats.ramDecodeP95Ms = percentile(decodeDurationsMs, p: 0.95)
            return stats
        }
    }

    public func hotPathCounters(reset: Bool = false) -> GridZoomHotPathCounters {
        lock.withLock {
            let snapshot = hotPath
            if reset { hotPath = GridZoomHotPathCounters() }
            return snapshot
        }
    }

    public func dbQueryCountDuringActivePinch() -> Int {
        lock.withLock { dbQueries.filter(\.duringActivePinch).count }
    }

    public func emit(_ event: String, _ fields: [String: String], throttleSeconds: TimeInterval = 0) {
        let now = Date()
        if throttleSeconds > 0 {
            let key = event + fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|")
            let shouldLog = lock.withLock {
                eventThrottle.shouldEmit(key: key, now: now, interval: throttleSeconds)
            }
            guard shouldLog else { return }
        }
        let logFields = sanitizedSupportFields(event: event, fields: fields) ?? fields
        let payload = logFields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        recordSupportEvent(event: event, fields: logFields, timestamp: now)
        #if DEBUG
            print("[\(event)] \(payload)")
        #endif
    }

    /// Adds an allowlisted event to the explicit support export without writing every high-rate
    /// sample to stdout or unified logging. Unsupported categories and fields are dropped.
    public func emitSupport(_ event: String, _ fields: [String: String]) {
        recordSupportEvent(event: event, fields: fields, timestamp: Date())
    }

    /// Runtime-gated unified-log diagnostics for interactive investigations. This intentionally bypasses the
    /// support-export ring buffer: callers must pass only fixed scalar fields, never identifiers, filenames,
    /// hashes, URLs, search text, paths, or user-visible content. Release builds stay silent unless the local
    /// app defaults or launch environment explicitly enables this path.
    public func emitDebug(
        _ event: String, _ fields: [String: String], throttleSeconds: TimeInterval = 0,
        throttleKey: String? = nil
    ) {
        emitDebug(event, fields: { fields }, throttleSeconds: throttleSeconds, throttleKey: throttleKey)
    }

    /// Builds a diagnostic payload only after logging is enabled and an explicit throttle key is
    /// admitted. Without a key, fields still define throttle identity as in the eager overload.
    /// The closure must obey the same fixed-scalar privacy contract as `emitDebug` above.
    public func emitDebug(
        _ event: String, fields: () -> [String: String], throttleSeconds: TimeInterval = 0,
        throttleKey: String? = nil
    ) {
        guard debugConsoleLogsEnabled() else { return }
        let now = Date()
        var evaluatedFields: [String: String]?
        if throttleSeconds > 0 {
            let identity: String
            if let throttleKey {
                identity = throttleKey
            } else {
                let value = fields()
                evaluatedFields = value
                identity = value.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: "|")
            }
            let key = "debug:" + event + ":" + identity
            let shouldLog = lock.withLock {
                eventThrottle.shouldEmit(key: key, now: now, interval: throttleSeconds)
            }
            guard shouldLog else { return }
        }
        let payload = (evaluatedFields ?? fields()).sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        #if DEBUG
            print("[\(event)] \(payload)")
        #endif
        Logger(subsystem: "at.oncloud.encryptedmemories", category: event)
            .notice("\(payload, privacy: .public)")
    }

    private func debugConsoleLogsEnabled() -> Bool {
        debugConsoleLogsAreEnabled
    }

    /// Privacy-safe local diagnostics for an explicit user-generated support export. Only fixed
    /// resource/MetricKit categories and allowlisted scalar fields enter this ring buffer; asset IDs,
    /// filenames, paths, hashes, search text, URLs, and error strings cannot be represented here.
    public func supportSnapshot() -> PhotoDiagnosticsSupportSnapshot {
        lock.withLock {
            PhotoDiagnosticsSupportSnapshot(
                counters: counters.filter { Self.supportCounterKeys.contains($0.key) },
                events: supportEvents
            )
        }
    }

    private func recordSupportEvent(event: String, fields: [String: String], timestamp: Date) {
        guard let sanitized = sanitizedSupportFields(event: event, fields: fields) else { return }
        lock.withLock {
            supportEvents.append(
                SupportDiagnosticEvent(
                    timestamp: timestamp,
                    category: event,
                    fields: sanitized
                ))
            if supportEvents.count > 200 {
                supportEvents.removeFirst(supportEvents.count - 200)
            }
        }
    }

    private func sanitizedSupportFields(event: String, fields: [String: String]) -> [String: String]? {
        let allowedFields: Set<String>
        switch event {
        case "ResourceState":
            allowedFields = [
                "execution", "headroom", "lowPower", "memory", "networkAvailableInterfaces", "networkConstrained",
                "networkExpensive", "networkInterfaces", "networkReachable", "recoveryPending", "thermal",
                "userInteraction", "visibleDemand",
            ]
        case "ResourcePermit":
            allowedFields = [
                "action", "active", "durationMs", "intent", "mode", "policyAdmitted", "reason",
                "waitMs", "workload", "yieldReason",
            ]
        case "MLIndexQuantum":
            allowedFields = [
                "assetLimit", "durationMs", "memoryAfter", "memoryBefore", "parallelism",
                "pipeline", "policyReason", "processed", "rampStep", "thermalAfter",
                "thermalBefore", "waitMs", "yieldReason",
            ]
        case "MemBudget":
            allowedFields = ["action", "headroom", "pressure", "reason", "tier"]
        case "MetricKit":
            allowedFields = ["diagnosticPayloads", "metricPayloads"]
        case "SearchSuggestions":
            allowedFields = ["action", "result", "durationMs"]
        case "DeviceIdentityKeychain":
            allowedFields = ["operation", "status"]
        case "MLCatalogRefresh":
            allowedFields = ["errorKind"]
        case "MetalGridRenderer":
            allowedFields = ["compositePipeline"]
        default:
            return nil
        }
        return fields.filter { allowedFields.contains($0.key) }
    }

    private func rectDescription(_ rect: CGRect) -> String {
        "(\(format(rect.minX)),\(format(rect.minY)),\(format(rect.width)),\(format(rect.height)))"
    }

    private func format(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func percentile(_ values: [Double], p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(max(Int(Double(sorted.count - 1) * p), 0), sorted.count - 1)
        return sorted[index]
    }
}
