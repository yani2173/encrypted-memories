import Foundation
import GridCore
import MediaFeedCore
import Observation
import PhotosCore

public struct TimelineRefreshResult: Sendable, Equatable {
    public let uploadedUID: PhotoUID?
    public let foundItem: PhotoItem?
    public let timelineCountBefore: Int
    public let timelineCountAfter: Int
    public let filterDescription: String
    public let elapsedMs: Double
    public let errorMessage: String?
    public let failureReason: TimelineRefreshFailureReason?
    public let addedUIDs: [PhotoUID]

    public var found: Bool { foundItem != nil }

    public init(
        uploadedUID: PhotoUID?,
        foundItem: PhotoItem?,
        timelineCountBefore: Int,
        timelineCountAfter: Int,
        filterDescription: String,
        elapsedMs: Double,
        errorMessage: String? = nil,
        failureReason: TimelineRefreshFailureReason? = nil,
        addedUIDs: [PhotoUID] = []
    ) {
        self.uploadedUID = uploadedUID
        self.foundItem = foundItem
        self.timelineCountBefore = timelineCountBefore
        self.timelineCountAfter = timelineCountAfter
        self.filterDescription = filterDescription
        self.elapsedMs = elapsedMs
        self.errorMessage = errorMessage
        self.failureReason = failureReason
        self.addedUIDs = addedUIDs
    }
}

@MainActor
@Observable
public final class TimelineViewModel {
    public enum State {
        case loading
        case empty
        case loaded([TimelineSection])
        case failed(String)
    }

    public private(set) var state: State = .loading {
        didSet { contentRevision &+= 1 }
    }
    /// Monotonic identity for the active route's canonical content. Search workers key results to it so a
    /// completion from an older route/load can never be published over newer sections.
    public private(set) var contentRevision: UInt64 = 0
    /// Shared first-presentation state. A non-empty cached inventory becomes presentable as soon as its visible
    /// Metal viewport is drawn; server-token validation continues without extending launch latency. Cached empty
    /// remains provisional until Proton confirms it, so the shell never flashes a false empty library.
    public private(set) var initialLibraryLoadState: LibraryLoadState = .initial
    /// Event-token baseline captured by the shared cache-validation policy. The host seeds its foreground
    /// monitor with this only after `load()` settles, so a mutation during startup cannot be consumed silently.
    public private(set) var initialLibraryChangeToken: String?
    /// A terminal startup failure requires account-scope recovery instead of an ordinary retry against the same
    /// backend. The host reads this after the coalesced initial load completes.
    public private(set) var initialLoadFailureReason: TimelineRefreshFailureReason?
    @ObservationIgnored private var initialAuthoritativeAddedUIDs: [PhotoUID] = []
    /// Flat, chronological items of the currently active route (whole library for `.all`, else the
    /// filtered tag/album/trash set) - backs selection and the upload-found lookup, not viewer paging.
    public private(set) var allItems: [PhotoItem] = [] {
        didSet {
            presentationItems = filter == .all ? allItems : Array(allItems.reversed())
            allItemsRevision &+= 1
        }
    }
    /// Changes with every `allItems` assignment, so a refresh can tell whether its off-main comparison still holds.
    @ObservationIgnored private var allItemsRevision: UInt64 = 0
    /// Reuse one display array across grid, viewer and chrome updates. Only collections reverse it;
    /// the full library retains its chronological order and bottom-trailing anchor.
    public private(set) var presentationItems: [PhotoItem] = []
    /// Stable identity snapshot of the whole `.all` library. Filter and map routes must never be
    /// interpreted as asset deletion by consumers such as Smart Search.
    public private(set) var wholeLibraryUIDs: [PhotoUID] = []
    public private(set) var wholeLibraryRevision: UInt64 = 0
    /// Monotonic revision for canonical item content. Unlike `wholeLibraryRevision`, this also advances
    /// when metadata changes without changing identity or order.
    public private(set) var wholeLibraryContentRevision: UInt64 = 0
    /// Completeness of the whole-library inventory published to source-aware derived-data consumers.
    public private(set) var wholeLibraryInventoryAuthority: SourceInventoryAuthority = .hydrating
    public private(set) var wholeLibraryInventoryAuthorityRevision: UInt64 = 0
    /// Revision of the identity/order that actually drives Metal grid presentation. Metadata enrichment can
    /// update `contentRevision` without rebuilding an unchanged whole-library grid.
    /// With pending photos the whole-library grid uses 4n + 2, so it never shares a value with the Proton
    /// timeline (4n) or a filtered route (4n + 1).
    public var gridSourceRevision: UInt64 {
        switch filter {
        case .all where showsPendingPhotos: pendingPresentation.membershipRevision &* 4 &+ 2
        case .all: wholeLibraryRevision &* 4
        default: contentRevision &* 4 &+ 1
        }
    }

    /// Local photos on their way to Proton, merged into the whole-library grid by the shared presenter. The
    /// Proton timeline stays in `allItems` and the whole-library snapshot for every remote-only consumer
    /// (search, Map, Smart Search, trash and export).
    public private(set) var pendingPresentation = PendingTimelinePresentation.empty

    public func setPendingPresentation(_ presentation: PendingTimelinePresentation) {
        pendingPresentation = presentation
    }

    /// True while the whole-library grid shows pending photos. It waits for the Proton timeline, so a slow
    /// first load never shows only local photos.
    public var showsPendingPhotos: Bool {
        filter == .all && !pendingPresentation.isCanonical && allRouteSnapshot != nil
            && !pendingPresentation.items.isEmpty
    }

    /// Local photos deleted before upload, shown in "Zuletzt gelöscht" with the Proton trash.
    public private(set) var pendingTrash = PendingTrashPresentation.empty

    public func setPendingTrash(_ trash: PendingTrashPresentation) {
        pendingTrash = trash
        // The trash grid rebuilds for a new list; other routes do not show it.
        if filter == .trash { contentRevision &+= 1 }
    }

    private var showsPendingTrash: Bool { filter == .trash && !pendingTrash.isEmpty }

    /// The route state the grid shows. A library without Proton photos still shows its pending photos, and an
    /// empty Proton trash still shows photos deleted before upload.
    public var gridState: State {
        guard showsPendingPhotos || showsPendingTrash else { return state }
        switch state {
        case .loaded, .empty: return .loaded(pendingSections)
        case .loading, .failed: return state
        }
    }

    /// Sections of the grid; see `gridState`.
    public var gridSections: [TimelineSection] {
        showsPendingPhotos || showsPendingTrash ? pendingSections : currentSections
    }

    /// Grid and viewer items; see `gridState`.
    public var gridItems: [PhotoItem] {
        if showsPendingPhotos { return pendingPresentation.items }
        if showsPendingTrash { return pendingTrash.merged(intoNewestFirst: presentationItems) }
        return presentationItems
    }

    /// The grid items with these identities, pending photos included, for actions on a selection.
    public func gridItems(matching uids: Set<PhotoUID>) -> [PhotoItem] {
        switch filter {
        case .all:
            return showsPendingPhotos
                ? pendingPresentation.snapshot.items(withUIDs: uids) : allLibraryItems(matching: uids)
        case .trash:
            return allItems.filter { uids.contains($0.uid) } + pendingTrash.items.filter { uids.contains($0.uid) }
        default:
            return allItems.filter { uids.contains($0.uid) }
        }
    }

    /// Upload badges of the whole-library grid, and "Nicht gesichert" badges in the trash.
    public var pendingUploadBadges: PendingUploadBadges {
        switch filter {
        case .all: pendingPresentation.uploadBadges
        case .trash: pendingTrash.badges
        default: .empty
        }
    }

    private var pendingSections: [TimelineSection] {
        let items = gridItems
        guard let first = items.first else { return [] }
        return [TimelineSection(id: "pending-presentation", date: first.captureTime, title: "", items: items)]
    }

    private let repository: PhotosRepository
    private let library: PhotoLibraryProvider?
    public let feed: ThumbnailFeedCore

    /// The active filter/album. `.all` is the whole library (fast SDK path); others use direct REST.
    public private(set) var filter: PhotoFilter = .all {
        didSet {
            if (filter == .all) != (oldValue == .all) {
                presentationItems = filter == .all ? allItems : Array(allItems.reversed())
            }
        }
    }

    public init(repository: PhotosRepository, feed: ThumbnailFeedCore, library: PhotoLibraryProvider? = nil) {
        self.repository = repository
        self.library = library
        self.feed = feed
    }

    /// Drains additions discovered while an authoritative startup load replaced a persisted inventory.
    public func takeInitialAuthoritativeAddedUIDs() -> [PhotoUID] {
        defer { initialAuthoritativeAddedUIDs.removeAll(keepingCapacity: false) }
        return initialAuthoritativeAddedUIDs
    }

    /// Recent filtered-route sections make revisits instant while fresh requests refresh behind. Core bounds this
    /// session cache to eight routes and protects the active route. `.all` stays in its retained whole-library
    /// snapshot instead of entering this cache.
    @ObservationIgnored private var filterCache = TimelineFilterCache()

    /// In-memory snapshot of the `.all` route's sections for this session, so returning to All Photos shows
    /// its content instantly from memory (no disk read, no re-dedup) - the counterpart to `filterCache` for
    /// the whole-library route, which otherwise re-materialized from the repository on every revisit. Kept in
    /// sync by `applyAllContent`, refreshes, and the semantic trash/restore commits below.
    @ObservationIgnored private var allRouteSnapshot: [TimelineSection]?
    /// SwiftUI/AppKit may transiently mount more than one timeline host while the window settles. All callers
    /// must await the same startup refresh so validation, persistence, and monitor-token capture run once.
    @ObservationIgnored private var initialLoadTask: Task<Void, Never>?
    /// Completion of that single-flight startup request is intentionally separate from presentation readiness:
    /// a rendered non-empty cache may uncover while this remains false and validation continues in the task.
    @ObservationIgnored private var initialLoadCompleted = false
    /// Whole-library crawl setup is background work. Keep it cancellable and outside the cached-token/visible
    /// launch path so checkpoint I/O and UID ordering never hold the launch veil up.
    @ObservationIgnored private var prefetchStartTask: Task<Void, Never>?
    /// Indexed view of the same `.all` projection. It is built together with the normalized sections off-main,
    /// then retained so Map/viewer lookups never rebuild a whole-library dictionary on the main actor.
    @ObservationIgnored private var wholeLibrarySnapshot = TimelineSnapshot()
    /// Successful server mutations are overlaid on every later fetch for this session. This closes the race
    /// where an older in-flight response completed after trash/restore and resurrected an item in a grid.
    @ObservationIgnored private var removals = TimelineRemovalOverlay()
    /// The last trash or restore projection. The next one waits for it.
    @ObservationIgnored private var lastCommit: Task<Void, Never>?

    /// `change` compares `projection` with the current whole-library snapshot. Without it, the comparison runs here.
    private func updateAllRouteSnapshot(
        _ projection: TimelineContentProjection,
        change: TimelineProjectionChange? = nil
    ) {
        let contentChanged = change?.contentChanged ?? (wholeLibrarySnapshot != projection.snapshot)
        allRouteSnapshot = projection.sections
        wholeLibrarySnapshot = projection.snapshot
        if contentChanged { wholeLibraryContentRevision &+= 1 }
        let uids = projection.uids
        guard change?.identitiesChanged ?? (uids != wholeLibraryUIDs) else { return }
        wholeLibraryUIDs = uids
        wholeLibraryRevision &+= 1
    }

    /// Revisions of everything that a refresh compares with. Equal values mean equal content.
    private var shownTimelineRevisions: [UInt64] {
        [allItemsRevision, wholeLibraryRevision, wholeLibraryContentRevision]
    }

    /// A refreshed route and its comparison with the content shown when the refresh started.
    private struct RouteRefresh: Sendable {
        let projection: TimelineContentProjection
        /// The route shows exactly these items already.
        let unchanged: Bool
        /// The comparison with the whole-library snapshot; nil for other routes.
        let wholeLibraryChange: TimelineProjectionChange?
    }

    /// Builds the route projection and compares it off the main actor, so an unchanged refresh makes no pass
    /// over the library on the main actor.
    private func prepareRefreshOffMain(
        _ sections: [TimelineSection],
        for route: PhotoFilter,
        shownItems: [PhotoItem],
        shownWholeLibrary: TimelineSnapshot?
    ) async -> RouteRefresh {
        let hidden = removals.hidden(on: route)
        return await Task.detached(priority: .userInitiated) {
            let projection = TimelineContentProjection(sections: sections).removing(hidden)
            return RouteRefresh(
                projection: projection,
                unchanged: Self.timelineContentUnchanged(projection.sections, vs: shownItems),
                wholeLibraryChange: shownWholeLibrary.map { TimelineProjectionChange(from: $0, to: projection) }
            )
        }.value
    }

    private func updateWholeLibraryAuthority(_ authority: SourceInventoryAuthority) {
        guard wholeLibraryInventoryAuthority != authority else { return }
        wholeLibraryInventoryAuthority = authority
        wholeLibraryInventoryAuthorityRevision &+= 1
    }

    /// Whether `sections` flattens to exactly `items` (same `PhotoItem`s, same order) without allocating the
    /// flattened array - the content-equality that lets an unchanged refresh/revisit skip state reassignment
    /// (no grid rebuild, no month-marker rebuild, no thumbnail-prefetch restart, scroll + selection preserved).
    /// Pure + `nonisolated`, so it is trivially testable and safe to evaluate off the main actor.
    public nonisolated static func timelineContentUnchanged(
        _ sections: [TimelineSection], vs items: [PhotoItem]
    ) -> Bool {
        var count = 0
        for section in sections { count += section.items.count }
        guard count == items.count else { return false }
        var i = 0
        for section in sections {
            for item in section.items {
                if item != items[i] { return false }
                i += 1
            }
        }
        return true
    }

    /// Records one refresh outcome per revision rather than per frame.
    private func noteRefresh(_ event: String) {
        PhotoDiagnostics.shared.increment("timeline.refresh.\(event)")
        PhotoDiagnostics.shared.emit(
            "TimelineRefreshPerf",
            [
                "event": event, "filter": Self.describe(filter), "rows": "\(allItems.count)",
            ])
    }

    /// Switches what the grid shows. `.all` reuses the cached/SDK timeline; tag & album views load
    /// from the direct endpoints. No-op if already showing that filter.
    public func select(_ newFilter: PhotoFilter) async {
        guard newFilter != filter else { return }
        filter = newFilter
        if newFilter == .all {
            await loadAll(force: true)  // cached full library, instant
        } else {
            await loadFiltered(newFilter)
        }
    }

    /// Re-runs the selected filter for the error-state Retry action. It does not fall back to `.all`.
    public func retry() async {
        if filter == .all { await loadAll(force: true) } else { await loadFiltered(filter) }
    }

    /// Loads a tag/album/trash filter, showing the `.loading` animation while it fetches (so a route switch never
    /// flashes a black/stale grid). A newer switch mid-flight wins (the `filter == f` guards).
    private func loadFiltered(_ f: PhotoFilter) async {
        // If this route was loaded earlier this session, show it immediately and
        // refresh behind. Only the very first visit shows the loading animation.
        if let cached = filterCache.load(f, activeRoute: filter) {
            let items = cached.flatMap(\.items)
            allItems = items
            state = items.isEmpty ? .empty : .loaded(cached)
        } else {
            state = .loading
        }
        do {
            let sections = await normalizeOffMain(try await (library?.timeline(filter: f) ?? []), for: f).sections
            guard filter == f else { return }
            filterCache.insert(sections, for: f, activeRoute: filter)
            let items = sections.flatMap(\.items)
            // Only swap the grid if the content actually changed - otherwise keep the instant view (and the
            // user's scroll position) untouched.
            if items != allItems {
                allItems = items
                state = items.isEmpty ? .empty : .loaded(sections)
                await feed.startPrefetch(ThumbnailCrawlOrder.newestToOldest(items))
            } else if case .loaded = state {
                // identical to what we already showed from cache - nothing to do
            } else {
                state = items.isEmpty ? .empty : .loaded(sections)  // first load, content equals stale allItems
            }
        } catch is CancellationError {
        } catch {
            guard filter == f else { return }
            // Keep the cached view on a refresh error; surface failure only if we have nothing to show.
            if case .loaded = state {} else { state = .failed(error.localizedDescription) }
        }
    }

    public func load() async {
        guard filter.hasTimeline else { return }
        if let initialLoadTask {
            await initialLoadTask.value
            return
        }
        guard !initialLoadCompleted else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadAll(force: false)
        }
        initialLoadTask = task
        await task.value
        initialLoadTask = nil
        initialLoadCompleted = true
    }

    /// Called by the Metal host after it actually rendered every visible item for the active library revision.
    /// The pure Core reducer decides whether that frame is eligible to uncover the shell.
    public func markInitialContentReady() {
        applyInitialLoad(.firstContentReady)
    }

    /// A rejected source inventory cannot render a first thumbnail. Preserve an already displayed library.
    public func reportInitialContentFailure() {
        let message = L10n.string("error.load_library_title")
        applyInitialLoad(.contentLoadFailed(message: message))
        if initialLibraryLoadState.failure != nil { state = .failed(message) }
    }

    /// Shows a caller-provided, already-resolved item set in the existing timeline grid without asking the
    /// backend for a server-side filter. Used by map cluster/member pins: the map owns which UIDs are grouped,
    /// while the grid, selection, export, trash, viewer, and thumbnail prefetch remain the normal timeline path.
    public func showTransientItems(_ items: [PhotoItem], sectionID: String) async {
        filter = .map
        let sections =
            items.isEmpty
            ? []
            : [TimelineSection(id: sectionID, date: items.first?.captureTime ?? .distantPast, title: "", items: items)]
        allItems = items
        state = items.isEmpty ? .empty : .loaded(sections)
        await feed.startPrefetch(ThumbnailCrawlOrder.newestToOldest(items))
    }

    /// Resolves map UID lists against the last known whole-library snapshot. This keeps Map taps independent
    /// of the sidebar route that happened to be visible underneath the map.
    public func allLibraryItems(matching uids: Set<PhotoUID>) -> [PhotoItem] {
        guard allRouteSnapshot != nil else { return allItems.filter { uids.contains($0.uid) } }
        return wholeLibrarySnapshot.items(withUIDs: uids)
    }

    /// Resolves map-cluster identities in canonical timeline order without materializing every PhotoItem.
    public func allLibraryUIDs(matching uids: Set<PhotoUID>) -> [PhotoUID] {
        guard allRouteSnapshot != nil else {
            return allItems.lazy.filter { uids.contains($0.uid) }.map(\.uid)
        }
        return wholeLibrarySnapshot.orderedUIDs(including: uids)
    }

    public func allLibraryItem(matching uid: PhotoUID) -> PhotoItem? {
        guard allRouteSnapshot != nil else { return allItems.first { $0.uid == uid } }
        return wholeLibrarySnapshot.item(for: uid)
    }

    /// The canonical whole-library Proton timeline, for the pending presenter.
    public var wholeLibraryTimeline: TimelineSnapshot { wholeLibrarySnapshot }

    /// Viewer paging for Map taps should use the whole-library snapshot when available, not whichever filtered
    /// timeline happened to be underneath the Map overlay.
    public var wholeLibraryItemsForViewer: [PhotoItem] {
        allRouteSnapshot == nil ? allItems : wholeLibrarySnapshot.items
    }

    /// Manual user-triggered reload of the currently visible library/filter.
    @discardableResult
    public func refreshLibrary() async -> TimelineRefreshResult {
        await refreshCurrent(uploadedUID: nil)
    }

    /// Reloads the current timeline after an upload and warms the new UID's thumbnail cache if known.
    @discardableResult
    public func refreshAfterUpload(uploadedUID: PhotoUID?) async -> TimelineRefreshResult {
        let result = await refreshCurrent(uploadedUID: uploadedUID)
        guard result.failureReason != .scopeAccessLost else { return result }
        if let uploadedUID {
            await feed.requestPriority(uploadedUID, priority: .visibleNow)
            _ = await feed.warmDecoded([uploadedUID], limit: 1)
        }
        return result
    }

    /// Commits a successful server-side trash mutation across the whole-library snapshot and every cached route.
    /// The O(library-size) transforms run off-main; the actor publishes only the completed projections.
    public func commitTrash(_ items: [PhotoItem]) async {
        await commitTrash(Set(items.map(\.uid)), knownItems: items)
    }

    /// Commits a trash that another feature already did on the server, such as the merge of duplicates. A photo that
    /// no listing has shown yet still stays hidden from every later listing; Recently Deleted gets the known ones.
    public func commitTrash(uids: Set<PhotoUID>) async {
        await commitTrash(uids, knownItems: wholeLibraryItemsForViewer.filter { uids.contains($0.uid) })
    }

    private func commitTrash(_ uids: Set<PhotoUID>, knownItems items: [PhotoItem]) async {
        guard !uids.isEmpty else { return }
        removals.trashed(uids)
        await afterEarlierCommits { [self] in await projectTrash(items, uids: uids) }
    }

    private func projectTrash(_ items: [PhotoItem], uids: Set<PhotoUID>) async {
        let all = allRouteSnapshot
        let caches = filterCache
        let cachedRoutes = caches.routesByRecency
        let activeFilter = filter
        let activeSections = currentSections
        let result = await Task.detached(priority: .userInitiated) {
            let all = all.map { TimelineContentProjection(sections: $0).removing(uids) }
            var updatedCaches: [PhotoFilter: [TimelineSection]] = [:]
            for route in cachedRoutes {
                let projection = TimelineContentProjection(sections: caches.snapshot(for: route) ?? [])
                updatedCaches[route] =
                    route == .trash
                    ? projection.inserting(items).sections
                    : projection.removing(uids).sections
            }
            let transient =
                activeFilter == .map
                ? TimelineContentProjection(sections: activeSections).removing(uids).sections
                : nil
            return (all, updatedCaches, transient)
        }.value

        var updatedCache = TimelineFilterCache(maximumEntries: filterCache.maximumEntries)
        for route in cachedRoutes {
            if let sections = result.1[route] {
                updatedCache.insert(sections, for: route, activeRoute: activeFilter)
            }
        }
        filterCache = updatedCache
        if let all = result.0 { updateAllRouteSnapshot(all) }
        publishCurrentRoute(transientMapSections: result.2)
    }

    /// Commits a successful restore: remove from Trash, insert into All Photos, and invalidate filtered caches
    /// whose membership must be resolved by the backend (albums/tags may have changed while the item was trashed).
    public func commitRestore(_ items: [PhotoItem]) async {
        let uids = Set(items.map(\.uid))
        guard !uids.isEmpty else { return }
        removals.restored(uids)
        await afterEarlierCommits { [self] in await projectRestore(items, uids: uids) }
    }

    private func projectRestore(_ items: [PhotoItem], uids: Set<PhotoUID>) async {
        let all = allRouteSnapshot
        let trash = filterCache.snapshot(for: .trash)
        let result = await Task.detached(priority: .userInitiated) {
            let all = all.map { TimelineContentProjection(sections: $0).inserting(items) }
            let trash = trash.map { TimelineContentProjection(sections: $0).removing(uids).sections }
            return (all, trash)
        }.value

        filterCache.removeAll()
        if let trash = result.1 {
            filterCache.insert(trash, for: .trash, activeRoute: filter)
        }
        if let all = result.0 { updateAllRouteSnapshot(all) }
        publishCurrentRoute()
    }

    /// Runs `projection` after every earlier trash or restore projection. Each projection reads the snapshot that the
    /// one before it published, so an earlier change can never overwrite a later one.
    private func afterEarlierCommits(_ projection: @escaping @MainActor () async -> Void) async {
        let earlier = lastCommit
        let commit = Task { @MainActor in
            await earlier?.value
            await projection()
        }
        lastCommit = commit
        await commit.value
    }

    /// Commits a successful empty-trash request against the Trash route even if the user switched routes while
    /// the network request was in flight.
    public func commitEmptyTrash(_ uids: Set<PhotoUID>) {
        guard !uids.isEmpty else { return }
        removals.trashEmptied(uids)
        filterCache.insert([], for: .trash, activeRoute: filter)
        if filter == .trash { publish([]) }
    }

    private func loadAll(force: Bool) async {
        if !force, case .loaded = state { return }  // load once
        initialLoadFailureReason = nil
        var cacheValidation = TimelineCacheValidation.refreshRequired(monitorBaseline: nil)
        var authoritativeLoadSucceeded = false
        var hadInventoryBaseline = allRouteSnapshot != nil

        // Show the in-memory `.all` snapshot when available. The first visit or a relaunch uses the
        // on-disk cache. `applyAllContent` reassigns state only when the content differs.
        if let snapshot = allRouteSnapshot {
            noteRefresh("snapshotHit")
            await displayAllContent(snapshot)
        } else {
            let cached = await repository.cachedTimelineSnapshot()
            // A sidebar switch may complete while this fetch is suspended. Do not publish `.all` content
            // after the active route changes. Re-check the route after each suspension point.
            guard filter == .all else { return }
            if let cached {
                hadInventoryBaseline = true
                let projection = await normalizeOffMain(cached.sections, for: .all)
                updateWholeLibraryAuthority(.cached)
                applyInitialLoad(.inventoryResolved(count: projection.snapshot.count, cached: true))
                await applyAllContent(projection)
                if !force {
                    cacheValidation = await TimelineCacheValidationPolicy.validate(
                        snapshot: cached,
                        repository: repository
                    )
                    guard filter == .all else { return }
                    if case .terminalFailure = cacheValidation {
                        initialLoadFailureReason = .scopeAccessLost
                        initialLibraryChangeToken = ""
                        return
                    }
                    if case .validated(let token) = cacheValidation {
                        updateWholeLibraryAuthority(.authoritative)
                        applyInitialLoad(
                            .authoritativeInventoryResolved(
                                count: projection.snapshot.count,
                                requiresNewFrame: false
                            ))
                        initialLibraryChangeToken = token
                        return
                    }
                }
            } else if case .loaded = state {
            } else {
                state = .loading
            }
        }

        do {
            let refreshed = try await repository.loadTimelineSnapshot()
            let projection = await normalizeOffMain(refreshed.sections, for: .all)
            guard filter == .all else { return }  // route switched mid-fetch - keep the new route, not All Photos
            initialAuthoritativeAddedUIDs =
                hadInventoryBaseline
                ? LibraryInventoryDelta.addedUIDs(previous: wholeLibraryUIDs, current: projection.uids)
                : []
            let requiresNewFrame = projection.uids != wholeLibraryUIDs
            updateWholeLibraryAuthority(.authoritative)
            applyInitialLoad(
                .authoritativeInventoryResolved(
                    count: projection.snapshot.count,
                    requiresNewFrame: requiresNewFrame
                ))
            // Only swap the grid if the library actually changed - otherwise keep the shown view (and the
            // user's scroll position) untouched.
            await applyAllContent(projection)
            initialLibraryChangeToken = refreshed.validationToken ?? cacheValidation.monitorBaseline
            authoritativeLoadSucceeded = true
        } catch is CancellationError {
            // ignore
        } catch {
            guard filter == .all else { return }
            initialLoadFailureReason = error is any LibraryChangeTerminalError ? .scopeAccessLost : .other
            applyInitialLoad(.failed(message: error.localizedDescription, retryable: true))
            // Keep showing the cached timeline on a refresh error; surface failure only if we have
            // nothing to show.
            if case .loaded = state {} else { state = .failed(error.localizedDescription) }
        }
        if !force {
            if !authoritativeLoadSucceeded {
                initialLibraryChangeToken = ""
            }
        }
    }

    private func applyInitialLoad(_ event: LibraryLoadEvent) {
        initialLibraryLoadState = LibraryLoadPolicy.reduce(initialLibraryLoadState, event)
    }

    /// Show `.all` content and restart the thumbnail crawl only when the flattened item sequence differs from
    /// the displayed sequence. The `.loaded`/`.empty` guard lets the first empty load leave `.loading`.
    private func applyAllContent(_ projection: TimelineContentProjection) async {
        let gridChanged = projection.uids != wholeLibraryUIDs
        updateAllRouteSnapshot(projection)
        await displayAllContent(projection.sections, restartPrefetch: gridChanged)
    }

    /// Re-publishes already retained `.all` sections without rebuilding their canonical snapshot/index.
    private func displayAllContent(_ sections: [TimelineSection], restartPrefetch: Bool = true) async {
        let settled: Bool
        switch state {
        case .loaded, .empty: settled = true
        default: settled = false
        }
        if settled, Self.timelineContentUnchanged(sections, vs: allItems) {
            noteRefresh("unchangedSkip")
            return
        }
        let items = sections.flatMap(\.items)
        allItems = items
        state = items.isEmpty ? .empty : .loaded(sections)
        noteRefresh("applied")
        if restartPrefetch {
            scheduleThumbnailPrefetch(items)
        }
    }

    private func scheduleThumbnailPrefetch(_ items: [PhotoItem]) {
        prefetchStartTask?.cancel()
        let feed = self.feed
        prefetchStartTask = Task {
            let uids = await Task.detached(priority: .utility) {
                ThumbnailCrawlOrder.newestToOldestFromChronological(items)
            }.value
            guard !Task.isCancelled else { return }
            await feed.startPrefetch(uids)
        }
    }

    private func refreshCurrent(uploadedUID: PhotoUID?) async -> TimelineRefreshResult {
        let start = ContinuousClock.now
        let before = allItems.count
        let previousWholeLibraryUIDs = wholeLibraryUIDs
        let f = filter  // the route this refresh is for
        let shownItems = allItems
        let shownWholeLibrary = f == .all ? wholeLibrarySnapshot : nil
        let shownRevisions = shownTimelineRevisions
        do {
            let refresh = await prepareRefreshOffMain(
                try await freshSectionsForCurrentFilter(), for: f, shownItems: shownItems,
                shownWholeLibrary: shownWholeLibrary)
            let projection = refresh.projection
            let sections = projection.sections
            guard filter == f else {  // a sidebar switch landed mid-refresh - don't clobber the new route
                return TimelineRefreshResult(
                    uploadedUID: uploadedUID, foundItem: nil,
                    timelineCountBefore: before, timelineCountAfter: allItems.count,
                    filterDescription: Self.describe(f), elapsedMs: elapsedMilliseconds(since: start),
                    errorMessage: "superseded by route switch",
                    failureReason: .superseded
                )
            }
            // The off-main comparisons hold while nothing else published since this refresh started.
            let comparison = shownRevisions == shownTimelineRevisions ? refresh : nil
            // No-op refresh: if fetched content matches the displayed content, do not
            // reassign state/allItems, refresh the route cache, or restart the crawl - the grid stays put
            // (scroll + selection preserved). The found-item lookup still runs against the current list.
            if comparison?.unchanged ?? Self.timelineContentUnchanged(sections, vs: allItems) {
                if f == .all {
                    updateWholeLibraryAuthority(.authoritative)
                    updateAllRouteSnapshot(projection, change: comparison?.wholeLibraryChange)
                }
                noteRefresh("unchangedSkip")
                let foundItem = uploadedUID.flatMap { uid in allItems.first { $0.uid == uid } }
                return TimelineRefreshResult(
                    uploadedUID: uploadedUID,
                    foundItem: foundItem,
                    timelineCountBefore: before,
                    timelineCountAfter: allItems.count,
                    filterDescription: Self.describe(filter),
                    elapsedMs: elapsedMilliseconds(since: start)
                )
            }
            let items = sections.flatMap(\.items)
            let wholeLibraryChange = comparison?.wholeLibraryChange
            let addedUIDs =
                f == .all
                ? wholeLibraryChange?.addedUIDs
                    ?? LibraryInventoryDelta.addedUIDs(previous: previousWholeLibraryUIDs, current: projection.uids)
                : []
            let gridChanged =
                f != .all || (wholeLibraryChange?.identitiesChanged ?? (projection.uids != wholeLibraryUIDs))
            allItems = items
            state = items.isEmpty ? .empty : .loaded(sections)
            if f == .all {
                updateWholeLibraryAuthority(.authoritative)
                updateAllRouteSnapshot(projection, change: wholeLibraryChange)
            } else {
                filterCache.insert(sections, for: f, activeRoute: filter)
            }  // keep the route's instant-revisit view fresh
            noteRefresh("applied")
            if gridChanged {
                await feed.startPrefetch(ThumbnailCrawlOrder.newestToOldest(items))
            }
            let foundItem = uploadedUID.flatMap { uid in items.first { $0.uid == uid } }
            return TimelineRefreshResult(
                uploadedUID: uploadedUID,
                foundItem: foundItem,
                timelineCountBefore: before,
                timelineCountAfter: items.count,
                filterDescription: Self.describe(filter),
                elapsedMs: elapsedMilliseconds(since: start),
                addedUIDs: addedUIDs
            )
        } catch is CancellationError {
            return TimelineRefreshResult(
                uploadedUID: uploadedUID,
                foundItem: nil,
                timelineCountBefore: before,
                timelineCountAfter: allItems.count,
                filterDescription: Self.describe(filter),
                elapsedMs: elapsedMilliseconds(since: start),
                errorMessage: "cancelled",
                failureReason: .cancelled
            )
        } catch {
            if case .loaded = state {} else { state = .failed(error.localizedDescription) }
            let failureReason: TimelineRefreshFailureReason
            if error is any LibraryChangeTerminalError {
                failureReason = .scopeAccessLost
            } else if error is any TimelineInventoryConvergenceError {
                failureReason = .pendingInventoryVisibility
            } else {
                failureReason = .other
            }
            return TimelineRefreshResult(
                uploadedUID: uploadedUID,
                foundItem: nil,
                timelineCountBefore: before,
                timelineCountAfter: allItems.count,
                filterDescription: Self.describe(filter),
                elapsedMs: elapsedMilliseconds(since: start),
                errorMessage: error.localizedDescription,
                failureReason: failureReason
            )
        }
    }

    private func freshSectionsForCurrentFilter() async throws -> [TimelineSection] {
        switch filter {
        case .all:
            return try await repository.loadTimeline()
        default:
            guard let library else { return [] }
            return try await library.timeline(filter: filter)
        }
    }

    private func normalizeOffMain(
        _ sections: [TimelineSection], for route: PhotoFilter
    ) async -> TimelineContentProjection {
        let hidden = removals.hidden(on: route)
        return await Task.detached(priority: .userInitiated) {
            TimelineContentProjection(sections: sections).removing(hidden)
        }.value
    }

    public var currentSections: [TimelineSection] {
        if case .loaded(let sections) = state { return sections }
        return []
    }

    private func publishCurrentRoute(transientMapSections: [TimelineSection]? = nil) {
        switch filter {
        case .all:
            if let allRouteSnapshot { publish(allRouteSnapshot) }
        case .map:
            if let transientMapSections { publish(transientMapSections) }
        default:
            if let cached = filterCache.load(filter, activeRoute: filter) { publish(cached) }
        }
    }

    private func publish(_ sections: [TimelineSection]) {
        let items = sections.flatMap(\.items)
        allItems = items
        state = items.isEmpty ? .empty : .loaded(sections)
    }

    private nonisolated static func describe(_ filter: PhotoFilter) -> String {
        switch filter {
        case .all: return "all"
        case .tag(let tag): return "tag:\(tag.title)"
        case .album(let id, let title): return "album:\(title):\(id)"
        case .sharedAlbum(let volumeID, let nodeID, let title): return "shared-album:\(title):\(volumeID)~\(nodeID)"
        case .trash: return "trash"
        case .map: return "map"
        case .duplicates: return "duplicates"
        }
    }

    private nonisolated func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: ContinuousClock.now)
        let components = elapsed.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
