import Foundation
import PhotosCore

/// An account-owned diagnostic source. Scans start only when the support exporter requests one.
public final class ThumbnailCacheSupportGroup: ThumbnailCacheSupportSource, @unchecked Sendable {
    private let caches: [ThumbnailCache]

    public init(_ caches: [ThumbnailCache]) { self.caches = caches }

    public func thumbnailCacheSupportSnapshot(deadline: ContinuousClock.Instant) async -> ThumbnailCacheSupportSnapshot
    {
        guard !caches.isEmpty else { return .unavailable }
        var entries: [ThumbnailCacheSupportSnapshot.Cache] = []
        var status = ThumbnailCacheSupportSnapshot.Availability.complete
        for cache in caches {
            let snapshot = await cache.thumbnailCacheSupportSnapshot(deadline: deadline)
            if snapshot.availability == .unavailable { return .unavailable }
            if snapshot.availability == .partial { status = .partial }
            for entry in snapshot.caches {
                guard !entries.contains(where: { $0.kind == entry.kind }) else { return .unavailable }
                entries.append(entry)
            }
            if status == .partial { break }
        }
        return ThumbnailCacheSupportSnapshot(availability: status, caches: entries)
    }
}

/// The caches whose encrypted disk size one Settings display shows. Two groups are equal only when they hold the
/// same cache instances, so a display that restarts its observation when the group changes follows a cache that
/// an account reload replaced instead of the retired one.
public struct ThumbnailCacheGroup: Hashable, Sendable {
    public let caches: [ThumbnailCache]

    public init(_ caches: [ThumbnailCache]) {
        self.caches = caches
    }

    public static func == (lhs: ThumbnailCacheGroup, rhs: ThumbnailCacheGroup) -> Bool {
        lhs.identities == rhs.identities
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identities)
    }

    private var identities: [ObjectIdentifier] { caches.map(ObjectIdentifier.init) }

    /// The exact byte total of the group's encrypted blobs, read off the caller's actor.
    public func diskSizeBytes() async -> Int64 {
        let caches = caches
        return await Task.detached(priority: .utility) {
            caches.reduce(Int64(0)) { $0 + $1.trackedDiskSizeBytes() }
        }.value
    }

    /// Runs `measure` once, and again after each change of the group's disk contents, at most once per `interval`,
    /// until the calling task is cancelled.
    public func followDiskChanges(
        interval: Duration = .seconds(10),
        isolation: isolated (any Actor)? = #isolation,
        _ measure: () async -> Void
    ) async {
        let changes = ThumbnailCache.diskChanges(of: caches, interval: interval)
        await measure()
        for await _ in changes {
            await measure()
        }
    }
}
