import PhotosCore

/// Session-local sections for filtered timeline routes.
///
/// The whole-library route has a separate retained `TimelineSnapshot` in `TimelineViewModel`. This cache stores
/// only filtered route sections and bounds them by count, so revisiting a recent album or tag remains instant
/// without creating a second canonical snapshot for the whole library.
public struct TimelineFilterCache: Sendable {
    public static let defaultMaximumEntries = 8

    public let maximumEntries: Int

    private struct Entry: Sendable {
        let sections: [TimelineSection]
        var lastAccess: UInt64
    }

    private var entries: [PhotoFilter: Entry] = [:]
    private var nextAccess: UInt64 = 0

    public init(maximumEntries: Int = Self.defaultMaximumEntries) {
        self.maximumEntries = max(1, maximumEntries)
    }

    public var count: Int { entries.count }
    public var routes: Set<PhotoFilter> { Set(entries.keys) }
    package var routesByRecency: [PhotoFilter] {
        entries.sorted { lhs, rhs in lhs.value.lastAccess < rhs.value.lastAccess }.map(\.key)
    }

    /// Returns a route without changing recency. Use `load` for a user-visible route revisit.
    public func snapshot(for route: PhotoFilter) -> [TimelineSection]? {
        entries[route]?.sections
    }

    /// Returns a route and marks it as recently used. The active route is protected from eviction.
    public mutating func load(
        _ route: PhotoFilter,
        activeRoute: PhotoFilter
    ) -> [TimelineSection]? {
        guard let entry = entries[route] else { return nil }
        touch(route)
        protect(activeRoute)
        return entry.sections
    }

    /// Stores filtered sections without making a duplicate canonical snapshot. `.all` and `.map` are excluded
    /// because the model owns those routes through `allRouteSnapshot` and transient presentation state.
    public mutating func insert(
        _ sections: [TimelineSection],
        for route: PhotoFilter,
        activeRoute: PhotoFilter
    ) {
        guard Self.isCacheable(route) else { return }
        nextAccess &+= 1
        entries[route] = Entry(sections: sections, lastAccess: nextAccess)
        protect(activeRoute)
        evictIfNeeded(activeRoute: activeRoute)
    }

    public mutating func remove(_ route: PhotoFilter) {
        entries.removeValue(forKey: route)
    }

    public mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }

    private mutating func touch(_ route: PhotoFilter) {
        guard entries[route] != nil else { return }
        nextAccess &+= 1
        entries[route]?.lastAccess = nextAccess
    }

    private mutating func protect(_ route: PhotoFilter) {
        guard Self.isCacheable(route), entries[route] != nil else { return }
        // A protected route remains recent without changing the cache's stored sections.
        touch(route)
    }

    private mutating func evictIfNeeded(activeRoute: PhotoFilter) {
        while entries.count > maximumEntries {
            let candidate =
                entries
                .filter { $0.key != activeRoute }
                .min { lhs, rhs in lhs.value.lastAccess < rhs.value.lastAccess }
            guard let candidate else { return }
            entries.removeValue(forKey: candidate.key)
        }
    }

    private static func isCacheable(_ route: PhotoFilter) -> Bool {
        switch route {
        case .all, .map, .duplicates: false
        default: true
        }
    }
}
