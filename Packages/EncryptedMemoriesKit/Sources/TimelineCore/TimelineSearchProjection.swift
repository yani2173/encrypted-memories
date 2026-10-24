import PhotosCore

public struct TimelineSearchProjectionKey: Hashable, Sendable {
    public let sourceRevision: UInt64
    public let query: String
    public let context: TimelineSearchContext
    public let semanticMatches: Set<PhotoUID>?
    public let refinement: TimelineRefinement
    /// Resolved result set of a selected structured suggestion; `nil` for ordinary text search.
    public let requiredUIDs: Set<PhotoUID>?

    public init(
        sourceRevision: UInt64,
        query: String,
        context: TimelineSearchContext,
        semanticMatches: Set<PhotoUID>?,
        refinement: TimelineRefinement = .all,
        requiredUIDs: Set<PhotoUID>? = nil
    ) {
        self.sourceRevision = sourceRevision
        self.query = query
        self.context = context
        self.semanticMatches = semanticMatches
        self.refinement = refinement
        self.requiredUIDs = requiredUIDs
    }
}

/// One authoritative, indexed result for a settled query. Both Apple hosts consume this value instead of
/// independently filtering or flattening the full library during view rendering.
public struct TimelineSearchProjection: Sendable {
    public let key: TimelineSearchProjectionKey
    public let sections: [TimelineSection]
    public let snapshot: TimelineSnapshot
    /// Stable display order for top-leading filter results. Core builds the reversed array once per projection,
    /// so repeated SwiftUI selection and chrome updates do not allocate another full result array.
    public let presentationItems: [PhotoItem]
    public let revision: UInt64

    public init(key: TimelineSearchProjectionKey, sections: [TimelineSection], revision: UInt64 = 0) {
        self.key = key
        let filtered = TimelineSearch.filter(
            sections,
            query: key.query,
            context: key.context,
            semanticMatches: key.semanticMatches,
            refinement: key.refinement,
            requiredUIDs: key.requiredUIDs
        )
        let projection = TimelineContentProjection(sections: filtered)
        self.sections = projection.sections
        snapshot = projection.snapshot
        if key.refinement.isActive || !TimelineSearchQuery(key.query).isEmpty || key.requiredUIDs != nil
            || (key.context.activeFilter != nil && key.context.activeFilter != .all)
        {
            presentationItems = Self.namesFirst(Array(projection.snapshot.items.reversed()), key: key)
        } else {
            presentationItems = projection.snapshot.items
        }
        self.revision = revision
    }

    /// For a query that reads as a file name, the photos whose name matches lead, newest first; the other results
    /// follow in their own order. Every other query keeps the date order.
    private static func namesFirst(_ items: [PhotoItem], key: TimelineSearchProjectionKey) -> [PhotoItem] {
        guard key.requiredUIDs == nil, let names = key.context.photoNames, !names.isEmpty,
            TimelineSearchQuery.looksLikeFileName(key.query)
        else { return items }
        let query = TimelineSearchQuery(key.query)
        var named: [PhotoItem] = []
        var others: [PhotoItem] = []
        others.reserveCapacity(items.count)
        for item in items {
            if query.matchesName(of: item.uid, in: names) {
                named.append(item)
            } else {
                others.append(item)
            }
        }
        return named + others
    }
}

/// Newest-wins worker for large-library search. The scan runs outside UI actors, the previous scan is
/// cooperatively cancelled, and a completion is returned only if no newer request superseded it.
public actor TimelineSearchProjectionCoordinator {
    private var generation: UInt64 = 0
    private var pendingTask: Task<TimelineSearchProjection, Never>?
    private var cachedProjection: TimelineSearchProjection?

    public init() {}

    #if DEBUG
        private var beforeProjection: (@Sendable () async -> Void)?

        /// Deterministic overlap seam; release builds retain the normal projection path only.
        init(beforeProjection: @escaping @Sendable () async -> Void) {
            self.beforeProjection = beforeProjection
        }
    #endif

    deinit {
        pendingTask?.cancel()
    }

    public func resolve(
        sections: [TimelineSection],
        key: TimelineSearchProjectionKey
    ) async -> TimelineSearchProjection? {
        if cachedProjection?.key == key { return cachedProjection }

        generation &+= 1
        let requestGeneration = generation
        pendingTask?.cancel()
        #if DEBUG
            let beforeProjection = beforeProjection
        #endif
        let task = Task.detached(priority: .userInitiated) {
            #if DEBUG
                await beforeProjection?()
            #endif
            return TimelineSearchProjection(key: key, sections: sections, revision: requestGeneration)
        }
        pendingTask = task
        let projection = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled, requestGeneration == generation else { return nil }
        cachedProjection = projection
        pendingTask = nil
        return projection
    }

    public func cancel() {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
        cachedProjection = nil
    }
}

/// The file names a search projection needs: the backend's name index while a text query is active, and nil
/// otherwise. An empty query ends the search in the backend too, so no decrypted names stay outside a search.
public enum TimelineFileNameSearchSource {
    public static func names(forQuery query: String, from backend: Any?) async -> PhotoNameIndex? {
        guard let provider = backend as? any PhotoNameSearchProvider else { return nil }
        guard !TimelineSearchQuery(query).isEmpty else {
            await provider.endPhotoNameSearch()
            return nil
        }
        return await provider.photoNameIndex()
    }
}
