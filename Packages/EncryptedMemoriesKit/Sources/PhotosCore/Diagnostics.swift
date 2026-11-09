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
        "backgroundWindows.endWaitTimedOut",
        "backgroundWindows.ledgerReset",
        "backgroundWindows.requestWentAheadOfALateOne",
        "backup.metadata.equalCoordinates",
        "duplicates.thumbnail.blankOver3Seconds",
        "folderScan.unreadableEntrySkips.missing",
        "folderScan.unreadableEntrySkips.permissionDenied",
        "folderScan.unreadableEntrySkips.transient",
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
        "smartSearch.catalogProtectionFailed",
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
    private var counters: [String: Int] = [:]
    private var eventThrottle = BoundedDiagnosticsThrottle()
    private var supportEvents: [SupportDiagnosticEvent] = []
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
            counters.removeAll()
            eventThrottle.removeAll()
            supportEvents.removeAll()
        }
    }

    public func recordDBQuery(queryName: String, durationMs: Double, rowsReturned: Int) {
        let ranOnMain = Thread.isMainThread
        if ranOnMain || durationMs > 5 {
            emit(
                "DBHealth",
                [
                    "query": queryName,
                    "durationMs": format(durationMs),
                    "rows": "\(rowsReturned)",
                    "main": "\(ranOnMain)",
                ])
        }
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
            allowedFields = [
                "action", "result", "durationMs", "event", "outcome", "versionMatches", "modelMatches",
                "evidenceComplete", "exactContent", "eligible", "librarySettled", "cacheContentSettled",
                "generationAllowed", "lowPower", "thermal", "memory", "foreground", "searchCount", "transferCount",
            ]
        case "MediaFeed":
            allowedFields = ["event", "items", "durationMs"]
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

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
