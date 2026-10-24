import Foundation

/// Weak local store references let both native hosts use the same exporter. Store keys only prevent duplicate
/// reads of the same file; they never enter a report. Sign-out closes stores and releases their owners.
public final class SupportDiagnosticsSources: @unchecked Sendable {
    public static let shared = SupportDiagnosticsSources()

    private struct WeakSource {
        let key: String
        weak var value: AnyObject?
    }

    private let lock = NSLock()
    private weak var library: (any LibrarySyncSupportSource)?
    private var queues: [WeakSource] = []
    private var journals: [WeakSource] = []
    private weak var places: (any PhotoPlaceSupportSource)?
    private weak var requests: (any RemoteRequestSupportSource)?
    private var pendingGrid = PendingGridSupportSnapshot()
    private let trail: SupportEventTrail

    public init(trail: SupportEventTrail = .shared) {
        self.trail = trail
    }

    public func registerLibrary(_ source: any LibrarySyncSupportSource) {
        lock.withLock {
            library = source
            queues.removeAll()
            journals.removeAll()
        }
    }

    /// An old session cannot clear the newer session's diagnostic sources.
    public func unregisterLibrary(_ source: any LibrarySyncSupportSource) {
        let unregistered = lock.withLock {
            guard library === source else { return false }
            library = nil
            queues.removeAll()
            journals.removeAll()
            pendingGrid = PendingGridSupportSnapshot()
            return true
        }
        // The trail holds identifiers of this account in memory.
        if unregistered { trail.clear() }
    }

    public func registerRequests(_ source: any RemoteRequestSupportSource) {
        lock.withLock { requests = source }
    }

    /// An old session cannot clear the newer session's request counts.
    public func unregisterRequests(_ source: any RemoteRequestSupportSource) {
        lock.withLock {
            if requests === source { requests = nil }
        }
    }

    public func requestSnapshot() async -> RemoteRequestSupportSnapshot? {
        let source = lock.withLock { requests }
        return await source?.remoteRequestSupportSnapshot()
    }

    public func registerPlaces(_ source: any PhotoPlaceSupportSource) {
        lock.withLock { places = source }
    }

    public func placeSnapshot() async -> [PlaceCandidateSupportSnapshot] {
        let source = lock.withLock { places }
        return await source?.photoPlaceSupportSnapshot() ?? []
    }

    public func registerQueue(_ source: any BackupQueueSupportSource, key: String) {
        lock.withLock {
            queues.removeAll { $0.value == nil }
            queues.append(WeakSource(key: key, value: source))
        }
    }

    public func registerEditReplacements(_ source: any EditReplacementSupportSource, key: String) {
        lock.withLock {
            journals.removeAll { $0.value == nil }
            journals.append(WeakSource(key: key, value: source))
        }
    }

    /// The pending grid replaces its counts after each merge and keeps a running merge count.
    public func publishPendingGrid(_ update: (inout PendingGridSupportSnapshot) -> Void) {
        lock.withLock { update(&pendingGrid) }
    }

    public func pendingGridSnapshot() -> PendingGridSupportSnapshot {
        lock.withLock { pendingGrid }
    }

    public func librarySnapshot(now: Date) async -> LibrarySyncSupportSnapshot {
        let source = lock.withLock { library }
        return await source?.librarySyncSupportSnapshot(now: now) ?? LibrarySyncSupportSnapshot()
    }

    public func queueSnapshots() -> [BackupQueueSupportSnapshot] {
        let sources = lock.withLock { Self.liveSources(queues).compactMap { $0 as? any BackupQueueSupportSource } }
        return sources.map { $0.backupSupportSnapshot() }
    }

    public func editReplacementSnapshots() -> [EditReplacementSupportSnapshot] {
        let sources = lock.withLock {
            Self.liveSources(journals).compactMap { $0 as? any EditReplacementSupportSource }
        }
        return sources.map { $0.editReplacementSupportSnapshot() }
    }

    private static func liveSources(_ sources: [WeakSource]) -> [AnyObject] {
        var seen = Set<String>()
        return sources.reversed().compactMap {
            guard let value = $0.value, seen.insert($0.key).inserted else { return nil }
            return value
        }
    }
}
