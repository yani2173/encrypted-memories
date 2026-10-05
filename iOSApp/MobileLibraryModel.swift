import AlbumCore
import AlbumsFeature
import DesignSystemCore
import Foundation
import LibrarySourceRuntime
import MLSearchAppleAdapter
import MLSearchBackgroundAppleAdapter
import MLSearchCore
import MLSearchFeature
import MapUIKitAdapter
import MediaByteCache
import MediaCacheCore
import MediaCacheUIKitAdapter
import MediaFeedCore
import MediaLocationCore
import Observation
import PhotoLibraryBackupAdapter
import PhotosCore
import ProtonAuth
import ProtonDriveBackend
import SwiftUI
import TimelineCore
import UIKit
import UploadCore

struct MobileRetryOwnerGraph {
    typealias Shutdown = @MainActor @Sendable () async -> Void

    static func makeCoordinator(
        platformTasks: @escaping Shutdown,
        smartSearch: @escaping Shutdown,
        locationCrawl: @escaping Shutdown,
        photoBackup: @escaping Shutdown,
        albumSync: @escaping Shutdown,
        facade: @escaping Shutdown
    ) throws -> AccountTeardownCoordinator {
        try AccountTeardownCoordinator(owners: [
            AccountTeardownOwner(id: "mobile.retry.platform-tasks", stage: .platformTasks, shutdown: platformTasks),
            AccountTeardownOwner(id: "mobile.retry.smart-search", stage: .smartSearch, shutdown: smartSearch),
            AccountTeardownOwner(id: "mobile.retry.location-crawl", stage: .locationCrawl, shutdown: locationCrawl),
            AccountTeardownOwner(id: "mobile.retry.photo-backup", stage: .photoBackup, shutdown: photoBackup),
            AccountTeardownOwner(id: "mobile.retry.album-sync", stage: .albumSync, shutdown: albumSync),
            AccountTeardownOwner(id: "mobile.retry.facade", stage: .facade, shutdown: facade),
        ])
    }
}

/// Captures the account/load generation that owns one user-initiated library mutation. Backend calls may ignore
/// cooperative cancellation, so every continuation must validate this lease before it publishes local state.
struct MobileLibraryMutationLease: Equatable, Sendable {
    let loadToken: Int
    let sessionUID: String

    func isCurrent(loadToken: Int, sessionUID: String?) -> Bool {
        self.loadToken == loadToken && self.sessionUID == sessionUID
    }
}

struct MobileScopeRecoveryIdentity: Equatable, Sendable {
    let failedSession: ProtonSession
    let failedLoadGeneration: Int
    let requestID: UInt64

    func matches(
        session: ProtonSession?,
        loadGeneration: Int,
        activeIdentity: MobileScopeRecoveryIdentity?
    ) -> Bool {
        session == failedSession
            && loadGeneration == failedLoadGeneration &+ 1
            && activeIdentity == self
    }
}

private struct MobileLibraryRefreshResult: Sendable {
    let outcome: LibraryChangeRefreshOutcome
    let failureReason: TimelineRefreshFailureReason?
}

/// Owns the single terminal-recovery task. Scheduling is synchronous on the main actor, so retry, sign-out, and
/// session replacement can observe and join the task before any recovery suspension occurs.
@MainActor
final class MobileScopeRecoveryCoordinator {
    private(set) var activeIdentity: MobileScopeRecoveryIdentity?
    private(set) var task: Task<Void, Never>?

    var isActive: Bool { task != nil }

    @discardableResult
    func schedule(
        identity: MobileScopeRecoveryIdentity,
        prepare: @MainActor @Sendable () -> Void,
        operation: @MainActor @Sendable @escaping () async -> Void
    ) -> Bool {
        guard task == nil, activeIdentity == nil else { return false }
        activeIdentity = identity
        prepare()
        let scheduled = Task { @MainActor [weak self] in
            await operation()
            self?.finish(identity: identity)
        }
        task = scheduled
        return true
    }

    func isCurrent(_ identity: MobileScopeRecoveryIdentity) -> Bool {
        activeIdentity == identity
    }

    @discardableResult
    func joinIfActive() async -> Bool {
        guard let task else { return false }
        await task.value
        return true
    }

    /// Invalidates the identity before cancellation. A late completion from this task cannot clear a newer task.
    func cancel() -> Task<Void, Never>? {
        let activeTask = task
        activeIdentity = nil
        task = nil
        activeTask?.cancel()
        return activeTask
    }

    private func finish(identity: MobileScopeRecoveryIdentity) {
        guard activeIdentity == identity else { return }
        activeIdentity = nil
        task = nil
    }
}

/// Runs the ordered asynchronous half of terminal scope recovery. The identity gate is checked after every
/// suspension, so an old session cannot purge or rebuild a replacement session.
@MainActor
struct MobileScopeRecoveryDriver {
    let isCurrent: @MainActor @Sendable () -> Bool
    let joinRetry: @MainActor @Sendable () async -> Void
    let retireOwners: @MainActor @Sendable () async -> Void
    let purgeLostScope: @MainActor @Sendable () async -> Void
    let rebuild: @MainActor @Sendable () -> Void

    func run() async {
        guard !Task.isCancelled, isCurrent() else { return }
        await joinRetry()
        guard !Task.isCancelled, isCurrent() else { return }
        await retireOwners()
        guard !Task.isCancelled, isCurrent() else { return }
        await purgeLostScope()
        guard !Task.isCancelled, isCurrent() else { return }
        rebuild()
    }
}

/// Owns signed-in iOS/iPadOS library state and composes the shared backend and thumbnail feed.
/// Core owns loading; this model sequences cached data, authoritative data, and crawling.
/// `@Observable` invalidates views per property, so non-grid tabs do not observe timeline snapshots.
@MainActor
@Observable
final class MobileLibraryModel {
    private enum TeardownFailure: Error {
        case purgeFailed
    }

    private struct SourceAnalysisStartupError: LocalizedError {
        var errorDescription: String? { L10n.string("error.load_library_title") }
    }

    /// Shared onboarding and loading policy. See `LibraryLoadState`.
    private(set) var loadState: LibraryLoadState = .initial
    /// Immutable timeline snapshot prepared off the main actor. Its index provides O(1) and O(k) lookups
    /// for viewer, share, and trash actions without scanning the library.
    private(set) var snapshot = TimelineSnapshot() {
        didSet { pendingGrid?.setRemote(snapshot) }
    }
    /// Changes only when a new canonical snapshot is published. Secondary grids use it to refresh their one
    /// indexed projection without recomputing it for unrelated SwiftUI state changes.
    private(set) var timelineRevision: UInt64 = 0
    /// The ordered items, for the grid and callers that pass the whole list (e.g. the viewer pager). Reads
    /// register a dependency on `snapshot`, so a timeline change invalidates only views that read items.
    var items: [PhotoItem] { snapshot.items }
    /// Timeline sections retained for the shared section-based `TimelineSearch` filter.
    private(set) var sections: [TimelineSection] = []
    /// Server favorites, writes in flight, and read state. Loading is independent of the timeline so a slow
    /// favorite endpoint never delays first thumbnails.
    private(set) var favoriteState = FavoriteState()
    /// Authoritative server favorite identities used by shared search semantics.
    var favoriteUIDs: Set<PhotoUID> { favoriteState.favorites }
    /// Favorites cannot be filtered honestly until the independent authoritative endpoint has settled.
    var favoriteFilterAvailability: FavoriteState.Availability { favoriteState.availability }
    /// Viewer and grid favorite buttons share one in-flight set. A repeated tap for the same identity cannot
    /// issue a second write while the first partial-success contract is still settling.
    var favoriteMutationsInFlight: Set<PhotoUID> { favoriteState.inFlight }
    private(set) var thumbnailFeed: UIKitThumbnailFeed?
    /// Keep the launch activity pill until known missing thumbnails finish, as well as later new-asset batches.
    var isBackgroundLoading: Bool { isThumbnailPrefetchLoading || isNewAssetThumbnailLoading }
    private var isThumbnailPrefetchLoading = false
    private var isNewAssetThumbnailLoading = false
    /// Automatic suggestion scans must wait for the library's startup and thumbnail work.
    var allowsAutomaticSuggestionRefresh: Bool {
        initialLibraryLoadSettled && loadState.hasSettled && !isBackgroundLoading && !isRefreshingLibrary
    }
    /// A complete local inventory can restore its matching suggestions before server validation or thumbnails.
    /// Source recovery still retires the account-owned scheduler before admitting replacement content.
    var allowsSuggestionCacheRestore: Bool {
        favoriteFilterAvailability == .available
            && loadState.knownCount != nil && !isRecoveringScope && !isSigningOut
    }
    /// Indicates that explicit sign-out is closing account owners and deleting account data.
    /// Transient session replacement does not set this flag.
    private(set) var isSigningOut = false
    /// Indicates that explicit sign-out closed every account owner but could not finish the local-data purge.
    /// The durable purge marker remains armed, so retry or the next process launch must finish cleanup.
    private(set) var signOutCleanupFailed = false
    /// Invalidates every presentation that can retain providers or rows from a lost Drive scope. Recovery keeps
    /// this state active until the replacement backend exists.
    private(set) var isRecoveringScope = false
    private(set) var scopePresentationRevision: UInt64 = 0
    private let thumbnailUpdateCoordinator = LibraryThumbnailUpdateCoordinator()

    /// The shared backend, exposed so the Albums / Map / Viewer tabs can reuse it without re-building anything.
    private(set) var backend: (any PhotosBackend)?
    private(set) var facade: ProtonClientFacade? {
        didSet {
            guard facade !== oldValue else { return }
            duplicates = facade?.exactDuplicates.map { makeDuplicatesModel($0) }
        }
    }
    /// The Duplicates screen of this account. Nil while the account cannot merge duplicates.
    private(set) var duplicates: ExactDuplicatesModel?
    /// Shared create/list/add state machine used by every native album presentation in this session.
    private(set) var albumActions: AlbumActionCoordinator?
    /// Account-scoped Photos-library backup controller shared with macOS.
    private(set) var photoBackup: PhotoLibraryBackupController?
    /// Local photos on their way to Proton, merged into the whole-library grid (shared with macOS).
    private(set) var pendingGrid: PendingGridSession?
    @ObservationIgnored private var pendingStore: PendingBackupManifestStore?
    @ObservationIgnored private var lastFavoriteIntents: [PhotoUID: Bool] = [:]
    /// The grid's view of the library: Proton photos plus pending local photos.
    private(set) var pendingPresentation = PendingTimelinePresentation.empty
    /// Local photos in "Zuletzt gelöscht", shown with the Proton trash.
    private(set) var pendingTrash = PendingTrashPresentation.empty
    /// Photos deleted before upload, for the Backup settings list.
    private(set) var excludedPendingTiles: [PendingTile] = []
    /// Changes when pending favorite intents change, so favorite displays refresh.
    private(set) var pendingFavoriteRevision: UInt64 = 0
    /// Offers to undo the last delete of pending photos.
    var undoNotice: UndoNoticeContent?
    /// Favorites as the app shows them, including the intents of pending photos.
    var displayedFavoriteUIDs: Set<PhotoUID> {
        _ = pendingFavoriteRevision
        return pendingGrid?.displayedFavorites(favoriteUIDs) ?? favoriteUIDs
    }
    /// Viewer media: pending photos from Apple Photos, every other photo from Proton.
    var viewerMedia: LocalPendingMediaRouter {
        LocalPendingMediaRouter(remote: backend, remoteVideo: backend, imageRequest: PhotoKitPlatformImages.request)
    }
    /// True while the grid shows pending photos. It waits for the Proton timeline, so a slow first load never
    /// shows only local photos.
    var showsPendingPhotos: Bool {
        !pendingPresentation.isCanonical && !pendingPresentation.items.isEmpty
            && (!items.isEmpty || loadState.isEmpty)
    }
    /// Items of the whole-library grid and viewer. Every remote-only consumer keeps using `items`.
    var gridItems: [PhotoItem] { showsPendingPhotos ? pendingPresentation.items : items }
    /// Content identity of `gridItems`: multiples of 4 for the Proton timeline, 4n + 2 with pending photos.
    /// Search projections use 4n + 1, so the three sources never share a value.
    var gridRevision: UInt64 {
        showsPendingPhotos ? pendingPresentation.membershipRevision &* 4 &+ 2 : timelineRevision &* 4
    }

    /// Position of `uid` in `gridItems`. O(1).
    func gridIndex(of uid: PhotoUID) -> Int? {
        showsPendingPhotos ? pendingPresentation.snapshot.index(of: uid) : snapshot.index(of: uid)
    }
    /// Account-scoped local-album sync controller shared with macOS.
    private(set) var albumSync: AlbumSyncController?
    /// Bumped by the shared album-sync controller after remote album mutations so Collections can
    /// refresh without reloading the whole timeline.
    private(set) var albumCatalogRevision = 0
    /// Account-scoped Smart Search session. MLSearchCore owns lifecycle decisions.
    @ObservationIgnored private let smartSearchSession = AppleSmartSearchSession(
        backgroundHost: AppleSmartSearchBackgroundCoordinator.shared
    )
    var smartSearch: MLSmartSearchController? { smartSearchSession.controller }
    let searchSuggestions = SmartSearchDiscoveryScheduler { latitude, longitude in
        await NativePlaceNameResolver.shared.cityName(latitude: latitude, longitude: longitude)
    }

    /// Encrypted GPS index shared with the Map tab. The per-account key protects it at rest.
    let locationIndex = PhotoLocationIndex()
    /// Loads the area the map opens at into MapKit's cache, so the map draws at once.
    @ObservationIgnored private let mapPrewarmer = PhotoMapPrewarmer()
    private var locationPrivacyStopTask: Task<Void, Never>?
    private let locationStore = PhotoLocationStore()
    private let locationCrawl = LocationCrawl()
    private var locationCrawlStarted = false
    private var locationCrawlGeneration: UInt64 = 0
    private var locationCrawlStartTask: Task<Void, Never>?
    private var locationInventoryRevision: UInt64 = 0
    private var locationCrawlInventoryRevision: UInt64 = 0
    private var locationInventoryTask: Task<LocationCrawlInventory, Never>?

    /// Encrypted thumbnail cache retained for Settings diagnostics and clear actions. Decoded previews remain
    /// in RAM, while video bytes are managed by the backend.
    private var thumbnailCache: ThumbnailCache?

    /// Encrypted on-disk cache for decrypted originals. The viewer seeds it; fullscreen opens and share/export
    /// reuse it before the network. Plaintext originals stay inside this AES-GCM store.
    private(set) var originalsCache: ThumbnailCache?

    /// LRU byte ceiling for `originalsCache`, enforced after each viewer store so a long session of large
    /// HEIC/video originals can't grow the on-disk cache without bound.
    let originalsCacheCapBytes: Int64 = 512 * 1024 * 1024

    private var configuredUID: String?
    private var store: SessionKeychainStore?
    private var session: ProtonSession?
    private var cacheContext: LocalMediaCacheContext?
    private var loadTask: Task<Void, Never>?
    /// Serializes account replacement: a newly authenticated session never opens SQLite stores
    /// until the previous facade has closed every handle and completed an explicit sign-out purge.
    private var teardownTask: Task<Void, Never>?
    /// Retains the already-claimed idempotent purge after a failure so the user can retry without reopening
    /// account owners. Process termination drops this value, but the durable marker recreates it at launch.
    @ObservationIgnored private var pendingSignOutPurgeClaim: BackupLocalDataPurge.Claim?
    private var transitionTask: Task<Void, Never>?
    private var prefetchStartTask: Task<Void, Never>?
    /// Lifecycle callbacks may arrive while the backend is still validating its cache. They record foreground
    /// state immediately, but monitoring is gated until this launch has one stable result or a handled failure.
    private var initialLibraryLoadSettled = false
    private var favoriteLoadTask: Task<Void, Never>?
    /// Resume and abandon work of "Keep Only Favorites". Teardown cancels it, so no journal write survives
    /// the account. The orchestrator's own admission gate joins a write that is already in flight.
    private var seriesDissolutionTask: Task<Void, Never>?
    /// Generation token used to reject off-main snapshot results from superseded loads or teardown.
    private var loadToken = 0
    private let libraryChangeMonitor = LibraryChangeMonitor()
    private let libraryRefreshCoalescer = LibraryRefreshCoalescer()
    private let uploadRefreshCoordinator = TimelineUploadRefreshCoordinator()
    private var applicationIsActive = true
    private(set) var isRefreshingLibrary = false
    /// Wakes analysis-only presentation after a source inventory becomes readable.
    private(set) var sourceAnalysisRevision: UInt64 = 0
    private var smartSearchAssets: MLAssetUniverse { smartSearchSession.assets }
    @ObservationIgnored private var primaryInventoryAuthority: SourceInventoryAuthority = .hydrating
    /// Successful trash and restore mutations of this session, laid over every later listing.
    @ObservationIgnored private var timelineRemovals = TimelineRemovalOverlay()
    @ObservationIgnored private var timelineMutationGeneration = 0
    @ObservationIgnored private let sourceAnalysis = LibrarySourceAnalysisSession()
    private var sourceAnalysisRuntime: LibrarySourceAnalysisRuntime? { sourceAnalysis.runtime }
    /// Coalesces repeated retry taps into one ordered transient retirement and one replacement load.
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// Coalesces terminal Drive scope recovery. This path keeps authentication but purges all lost-scope data.
    @ObservationIgnored private let scopeRecoveryCoordinator = MobileScopeRecoveryCoordinator()
    @ObservationIgnored private var nextScopeRecoveryID: UInt64 = 0

    // MARK: - Pending grid

    private func configurePendingGrid(
        store: PendingBackupManifestStore?,
        photoBackup: PhotoLibraryBackupController,
        client: ProtonClientFacade,
        feed: UIKitThumbnailFeed
    ) {
        pendingStore = store
        guard let store,
            let session = PendingGridSession(
                store: store,
                photoBackup: photoBackup,
                remote: ProtonPendingRemoteEffects(facade: client)
            )
        else { return }
        session.presenter.onChange = { [weak self] presentation in
            self?.pendingPresentation = presentation
        }
        session.onListsChange = { [weak self, weak session] in
            guard let self, let session else { return }
            pendingTrash = session.trash
            excludedPendingTiles = session.excludedTiles
        }
        session.onPendingChange = { [weak self] snapshot in
            guard let self, snapshot.favoriteIntents != lastFavoriteIntents else { return }
            lastFavoriteIntents = snapshot.favoriteIntents
            pendingFavoriteRevision &+= 1
        }
        let albums = client.albums
        Task { [weak session] in
            await albums.setPendingAlbumAdds { [weak session] uids, albumID in
                await session?.addToAlbum(uids, albumID: albumID) ?? false
            }
        }
        session.attachFeed(feed.feedCore, imageRequest: PhotoKitPlatformImages.request)
        pendingGrid = session
        session.setRemote(snapshot)
        session.start()
    }

    /// Detaches the pending grid from the model. The caller closes the session before the backup controller
    /// shuts down, and the store after it.
    private func retirePendingGrid() -> (session: PendingGridSession?, store: PendingBackupManifestStore?) {
        let retired = (pendingGrid, pendingStore)
        pendingGrid = nil
        pendingStore = nil
        pendingPresentation = .empty
        pendingTrash = .empty
        excludedPendingTiles = []
        undoNotice = nil
        lastFavoriteIntents = [:]
        pendingFavoriteRevision &+= 1
        return retired
    }

    func configure(session: ProtonSession?, store: SessionKeychainStore) {
        guard let session else {
            self.store = store
            // Cold-launch cleanup belongs to MobileSessionModel. An unconfigured library must
            // not claim the same pending reset while that startup transaction is still running.
            guard self.session != nil || configuredUID != nil else { return }
            teardown()
            return
        }
        guard !scopeRecoveryCoordinator.isActive, !isRecoveringScope else { return }
        self.store = store
        // Reuse the configured account on relaunch or route changes without restarting the crawl.
        guard configuredUID != session.uid || backend == nil else { return }
        // Another account closes its services, pending grid session, and stores before this one starts.
        if let configuredUID, configuredUID != session.uid { teardown() }
        self.session = session
        if let teardownTask {
            configuredUID = session.uid
            loadState = .preparingInventory
            transitionTask?.cancel()
            transitionTask = Task { @MainActor [weak self] in
                await teardownTask.value
                guard let self,
                    !Task.isCancelled,
                    self.session == session,
                    !self.isSigningOut,
                    !BackupLocalDataPurge.isPurgePending()
                else { return }
                self.teardownTask = nil
                self.transitionTask = nil
                self.start(session: session, store: store)
            }
            return
        }
        start(session: session, store: store)
    }

    /// Moves items to Trash through the shared backend. The move is recoverable, not permanent.
    /// On success, the items leave the visible library. Errors propagate to the caller.
    ///
    /// Photos that are not backed up yet leave the backup instead; the local photo stays in Apple Photos. An
    /// undo notice offers to take that back.
    func trashItems(_ uids: Set<PhotoUID>) async throws {
        guard let backend, !uids.isEmpty else { return }
        let split = LocalPendingSplit(uids)
        if !split.local.isEmpty {
            guard let pendingGrid, await pendingGrid.delete(split.local) else { throw CancellationError() }
            offerUndo(forDeleted: split.local)
        }
        guard !split.remote.isEmpty else { return }
        try await removeFromVisibleLibrary(Set(split.remote)) { try await backend.trash(split.remote) }
    }

    private func offerUndo(forDeleted uids: [PhotoUID]) {
        undoNotice = UndoNoticeContent(
            message: L10n.string("pending.delete_notice"), systemImage: "icloud.slash"
        ) { [weak self] in
            guard let pendingGrid = self?.pendingGrid else { return }
            Task { await pendingGrid.restore(uids) }
        }
    }

    /// True when "Keep Only Favorites" may run for the series: uploads work, and every photo of the series
    /// lies in the account's own library. A series of a shared album never qualifies.
    func canKeepOnlySeriesFavorites(seriesUIDs: [PhotoUID]) async -> Bool {
        guard let dissolution = facade?.seriesDissolution else { return false }
        return await dissolution.canDissolve(seriesUIDs: seriesUIDs)
    }

    /// Saves the favorites of a series as standalone photos and moves the whole series to Trash. The shared
    /// orchestrator journals the operation, so calling this again after a failure resumes it without duplicates.
    func keepOnlySeriesFavorites(
        seriesMainUID: PhotoUID,
        seriesUIDs: [PhotoUID],
        favoriteUIDs: [PhotoUID],
        onProgress: @escaping @Sendable (SeriesDissolutionProgress) -> Void
    ) async throws {
        guard let dissolution = facade?.seriesDissolution else { throw SeriesDissolutionError.notOwnLibrary }
        try await removeFromVisibleLibrary(Set(seriesUIDs)) {
            try await dissolution.keepOnlyFavorites(
                seriesMainUID: seriesMainUID,
                seriesUIDs: seriesUIDs,
                favoriteUIDs: favoriteUIDs,
                onProgress: onProgress
            )
        }
        // The standalone copies are new library photos; the refresh brings them into the timeline.
        refreshAfterLocalUpload()
    }

    /// The user left "Keep Only Favorites" after a failure. The pending journal goes away, so no later activation
    /// can finish the operation without the user. Copies that are already saved stay as standalone photos.
    func abandonKeepOnlySeriesFavorites(seriesMainUID: PhotoUID) {
        guard let dissolution = facade?.seriesDissolution else { return }
        let previous = seriesDissolutionTask
        seriesDissolutionTask = Task {
            await previous?.value
            do {
                try await dissolution.abandon(seriesMainUID: seriesMainUID)
            } catch {
                DebugLog.log("series: abandoning the pending operation failed - \(error)")
            }
        }
    }

    /// A crash or an error can interrupt "Keep Only Favorites" in its trash step, after the user's consent and
    /// every copy are final. Activation finishes only such operations. The series is already in the trash then,
    /// so the authoritative refresh removes it and adds the copies. The optimistic removal of the interactive
    /// path is not used: it advances the timeline mutation generation and would reject the initial load.
    private func resumePendingSeriesDissolutions(_ dissolution: SeriesDissolutionOrchestrator) async {
        do {
            let outcomes = try await dissolution.resumePending()
            var didFinishAny = false
            for outcome in outcomes {
                switch outcome.result {
                case .success:
                    didFinishAny = true
                    DebugLog.log("series: resumed trash step finished photos=\(outcome.seriesUIDs.count)")
                case .failure(let error):
                    DebugLog.log("series: resumed trash step failed, the journal stays pending - \(error)")
                }
            }
            if didFinishAny { refreshAfterLocalUpload() }
        } catch {
            DebugLog.log("series: pending operations could not be read - \(error)")
        }
    }

    /// Runs a remote mutation that takes `uids` out of the library, then removes them from the visible timeline.
    private func removeFromVisibleLibrary(
        _ uids: Set<PhotoUID>,
        after remoteMutation: () async throws -> Void
    ) async throws {
        // No session means no library to mutate. The caller must see that nothing happened: a remote
        // operation like "Keep Only Favorites" would otherwise report success without doing anything.
        guard let mutationLease = currentMutationLease() else { throw CancellationError() }
        try Task.checkCancellation()
        let locationStoreLease = locationStore.captureSessionLease()
        try await remoteMutation()
        try requireCurrentMutation(mutationLease)
        timelineRemovals.trashed(uids)
        timelineMutationGeneration &+= 1
        let generation = timelineMutationGeneration
        let currentSections = sections
        let allRemovals = timelineRemovals.hiddenFromLibrary
        let result = await Task.detached(priority: .userInitiated) {
            let projection = TimelineContentProjection(sections: currentSections).removing(allRemovals)
            return (projection, Set(projection.snapshot.items.map(\.uid)))
        }.value
        try requireCurrentMutation(mutationLease)
        guard generation == timelineMutationGeneration else { return }
        publish(result.0, locationInventoryChanged: true)
        apply(.inventoryResolved(count: result.0.snapshot.count, cached: false))
        await locationIndex.retainOnly(
            result.1,
            persistTo: locationStoreLease == nil ? nil : locationStore,
            sessionLease: locationStoreLease
        )
        try requireCurrentMutation(mutationLease)
    }

    private func makeDuplicatesModel(_ finder: any ExactDuplicateMerging) -> ExactDuplicatesModel {
        ExactDuplicatesModel(finder: finder) { [weak self] trashed in
            await self?.removeMergedDuplicates(Set(trashed))
        }
    }

    /// The finder already moved the photos to Recently Deleted; the library only stops showing them, and the kept
    /// photos show the favorite tag that the merge carried over. The optimistic removal advances the timeline
    /// mutation generation, which rejects an initial load in flight, so it waits for that load. The overlay hides
    /// the photos from every listing that starts meanwhile.
    private func removeMergedDuplicates(_ uids: Set<PhotoUID>) async {
        timelineRemovals.trashed(uids)
        var awaitedLoad: Task<Void, Never>?
        while !initialLibraryLoadSettled, let load = loadTask, load != awaitedLoad {
            awaitedLoad = load
            await load.value
        }
        try? await removeFromVisibleLibrary(uids) {}
        await reloadFavorites(trashed: uids)
    }

    /// Reads the favorites again. A failed read only drops the trashed photos from them.
    private func reloadFavorites(trashed: Set<PhotoUID>) async {
        guard let backend, let activeSession = session else { return }
        let loadGeneration = loadToken
        let read = favoriteState.beginLoad()
        let loaded = try? await backend.favoriteUIDs()
        guard loadGeneration == loadToken, session == activeSession else { return }
        favoriteState.finishLoad(loaded, for: read)
        if loaded == nil { favoriteState.removeTrashed(trashed) }
    }

    func restoreItems(_ items: [PhotoItem]) async throws {
        let local = items.filter(\.uid.isLocalPending)
        if !local.isEmpty {
            // A photo deleted before upload goes back into the backup queue.
            guard let pendingGrid, await pendingGrid.restore(local.map(\.uid)) else { throw CancellationError() }
        }
        let items = items.filter { !$0.uid.isLocalPending }
        guard let backend, let mutationLease = currentMutationLease(), !items.isEmpty else { return }
        try Task.checkCancellation()
        let locationStoreLease = locationStore.captureSessionLease()
        let uids = Set(items.map(\.uid))
        try await backend.restore(Array(uids))
        try requireCurrentMutation(mutationLease)
        pendingGrid?.photosRestored(Array(uids))
        timelineRemovals.restored(uids)
        timelineMutationGeneration &+= 1
        let generation = timelineMutationGeneration
        let currentSections = sections
        let remainingRemovals = timelineRemovals.hiddenFromLibrary
        let result = await Task.detached(priority: .userInitiated) {
            let projection = TimelineContentProjection(sections: currentSections)
                .inserting(items)
                .removing(remainingRemovals)
            return (projection, Set(projection.snapshot.items.map(\.uid)))
        }.value
        try requireCurrentMutation(mutationLease)
        guard generation == timelineMutationGeneration else { return }
        let shouldRestartLocationCrawl = locationCrawlStarted
        publish(result.0, locationInventoryChanged: true)
        apply(.inventoryResolved(count: result.0.snapshot.count, cached: false))
        await locationIndex.retainOnly(
            result.1,
            persistTo: locationStoreLease == nil ? nil : locationStore,
            sessionLease: locationStoreLease
        )
        try requireCurrentMutation(mutationLease)
        if shouldRestartLocationCrawl {
            locationCrawlStarted = false
            startLocationCrawlIfNeeded()
        }
    }

    /// Optimistically toggles selected favorites through the shared Core projection, then rolls back only identities
    /// that the backend reports as failed. The return value lets the native host present a concise error.
    @discardableResult
    func toggleFavorite(_ selection: Set<PhotoUID>) async -> Bool {
        guard let backend, let activeSession = session else { return false }
        let split = LocalPendingSplit(selection)
        // One direction for the whole selection, pending photos included; the backup applies their part later.
        guard let target = FavoriteMutationPolicy.target(for: selection, current: displayedFavoriteUIDs) else {
            return true
        }
        var localSucceeded = true
        if !split.local.isEmpty {
            localSucceeded = await pendingGrid?.setFavorite(split.local, favorite: target) ?? false
        }
        let mutationGeneration = loadToken
        guard let request = favoriteState.beginWrite(selection: Set(split.remote), target: target) else {
            return localSucceeded
        }
        let failed = await FavoriteState.perform(request) { try await backend.setFavorites($0, $1) }
        // A write of an earlier session must not touch the state of the current one.
        guard mutationGeneration == loadToken, session == activeSession else { return true }
        favoriteState.finishWrite(request, failed: failed)
        return localSucceeded && failed.isDisjoint(with: request.requested)
    }

    @discardableResult
    func toggleFavorite(_ uid: PhotoUID) async -> Bool {
        await toggleFavorite([uid])
    }

    private func currentMutationLease() -> MobileLibraryMutationLease? {
        guard let session else { return nil }
        return MobileLibraryMutationLease(loadToken: loadToken, sessionUID: session.uid)
    }

    private func requireCurrentMutation(_ lease: MobileLibraryMutationLease) throws {
        guard lease.isCurrent(loadToken: loadToken, sessionUID: session?.uid) else {
            throw CancellationError()
        }
    }

    /// Empties the Proton trash. Photos deleted before upload only leave the list: they stay excluded from the
    /// backup and stay in Apple Photos.
    func emptyTrash(includesProtonTrash: Bool = true) async throws {
        guard let backend else { return }
        if let pendingGrid, !pendingTrash.isEmpty {
            guard await pendingGrid.removeFromTrashList(pendingTrash.items.map(\.uid)) else {
                throw CancellationError()
            }
        }
        if includesProtonTrash { try await backend.emptyTrash() }
    }

    /// Deletes only the album container through the shared AlbumCore facade. The backend deliberately uses
    /// Proton's safe `DeleteAlbumPhotos=0` contract, so photos that exist only in the album cause an honest
    /// failure instead of being permanently deleted. The revision refreshes every album presentation on success.
    func deleteAlbum(_ albumID: String) async throws {
        guard let facade else { return }
        try await facade.albums.deleteAlbum(albumID: albumID)
        albumCatalogRevision &+= 1
    }

    func removeItems(_ uids: [PhotoUID], fromAlbum albumID: String) async throws {
        guard let facade else { return }
        try await facade.albums.removePhotos(uids, from: albumID)
        albumCatalogRevision &+= 1
    }

    func noteAlbumsChanged() {
        albumCatalogRevision &+= 1
    }

    /// Returns the position of `uid` through the snapshot index.
    func index(of uid: PhotoUID) -> Int? { snapshot.index(of: uid) }

    /// Returns selected items in timeline order through the snapshot index.
    func selectedItems(_ uids: Set<PhotoUID>) -> [PhotoItem] { gridSnapshot.items(withUIDs: uids) }

    /// ID-only server actions retain every selected identity even if a concurrent timeline refresh replaced
    /// the projection between the tap and presentation of the destination sheet.
    func selectedUIDs(_ uids: Set<PhotoUID>) -> [PhotoUID] { gridSnapshot.orderedUIDs(including: uids) }

    /// The whole-library grid's snapshot: it also holds pending photos, so selections of them resolve.
    private var gridSnapshot: TimelineSnapshot { showsPendingPhotos ? pendingPresentation.snapshot : snapshot }

    /// Returns the encrypted thumbnail-cache size without blocking the main actor on file I/O.
    func cacheDiskSizeBytes() async -> Int64 {
        guard let cache = thumbnailCache else { return 0 }
        return await Task.detached { cache.diskSizeBytes() }.value
    }

    /// Clears the thumbnail cache and restarts prefetch. The feed keeps decoded thumbnails, and only the
    /// cache-owned directory is removed.
    func clearCache() async {
        guard let cache = thumbnailCache else { return }
        if let feed = thumbnailFeed {
            let token = loadToken
            if let runtime = sourceAnalysisRuntime {
                // Visible publication precedes async source admission. Join that boundary before clearing;
                // the bound feed owns the authorized crawl order, including photos from additional sources.
                let admission = await synchronizePrimarySourceInventory(items, authority: primaryInventoryAuthority)
                guard sourceAnalysisRuntime === runtime else { return }
                // A newer host generation may win while the existing runtime drains its pending inventory.
                guard admission == .accepted || admission == .superseded else {
                    DebugLog.log("thumbnail cache clear skipped: source inventory was not admitted")
                    return
                }
            }
            guard !Task.isCancelled, token == loadToken, thumbnailFeed === feed else { return }
            await feed.clearCacheAndRestartPrefetch()
        } else {
            await cache.clear()
        }
    }

    /// Retires account owners before starting a replacement load after failure.
    func retry() async {
        guard let session, let store else { return }
        if await scopeRecoveryCoordinator.joinIfActive() { return }
        if let retryTask {
            await retryTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.retryTask = nil }
            await self.retireForRetry()
            guard !Task.isCancelled, self.session == session else { return }
            self.configuredUID = nil
            self.start(session: session, store: store, preserveVisibleSnapshot: true)
        }
        retryTask = task
        await task.value
    }

    /// Schedules a Drive-scope recovery for the exact session and load that observed the terminal result. The
    /// synchronous preparation fences old publishers and removes inaccessible content before the task can run.
    private func scheduleScopeRecovery(
        failedSession: ProtonSession,
        failedStore: SessionKeychainStore,
        failedLoadGeneration: Int
    ) {
        guard !scopeRecoveryCoordinator.isActive,
            session == failedSession,
            loadToken == failedLoadGeneration
        else { return }

        nextScopeRecoveryID &+= 1
        let identity = MobileScopeRecoveryIdentity(
            failedSession: failedSession,
            failedLoadGeneration: failedLoadGeneration,
            requestID: nextScopeRecoveryID
        )
        let activeRetry = retryTask
        let activeThumbnailCache = thumbnailCache
        let activeOriginalsCache = originalsCache
        let locationStore = locationStore
        let locationIndex = locationIndex
        let policy = ProtonDriveBackendPolicy.standard(
            libraryDatabasePolicy: ProtonDriveBackendPolicy.mobileLibraryDatabasePolicy,
            videoCacheBudgetBytes: 128 * 1024 * 1024
        )

        let driver = MobileScopeRecoveryDriver(
            isCurrent: { [weak self] in
                self?.scopeRecoveryIsCurrent(identity) == true
            },
            joinRetry: {
                await activeRetry?.value
            },
            retireOwners: { [weak self] in
                await self?.retireForRetry(advanceLoadToken: false)
            },
            purgeLostScope: { [weak self] in
                guard let self else { return }
                self.cacheContext = nil
                self.thumbnailCache = nil
                self.originalsCache = nil
                await Task.detached(priority: .utility) {
                    activeThumbnailCache?.clearForSignOut()
                    activeOriginalsCache?.clearForSignOut()
                    locationStore.clear()
                    ProtonDriveBackendFactory.purgeLocalAccountData(uid: failedSession.uid, policy: policy)
                }.value
            },
            rebuild: { [weak self] in
                guard let self else { return }
                self.configuredUID = nil
                self.start(session: failedSession, store: failedStore, preserveVisibleSnapshot: false)
            }
        )

        let scheduled = scopeRecoveryCoordinator.schedule(
            identity: identity,
            prepare: { [weak self] in
                guard let self else { return }
                // Never leave inaccessible rows or provider-backed presentations visible during teardown.
                self.isRecoveringScope = true
                self.scopePresentationRevision &+= 1
                self.loadToken &+= 1
                activeRetry?.cancel()
                self.prefetchStartTask?.cancel()
                self.isThumbnailPrefetchLoading = false
                self.favoriteLoadTask?.cancel()
                self.seriesDissolutionTask?.cancel()
                self.snapshot = TimelineSnapshot()
                self.sections = []
                self.favoriteState.reset(keepingFavorites: false)
                self.timelineRemovals = TimelineRemovalOverlay()
                self.timelineMutationGeneration &+= 1
                self.timelineRevision &+= 1
                self.initialLibraryLoadSettled = false
                self.loadState = .preparingInventory
                locationIndex.replaceAll([])
                locationIndex.updateScanProgress(PhotoLocationScanProgress())
            },
            operation: {
                await driver.run()
            }
        )
        precondition(scheduled, "Scope recovery changed during synchronous scheduling")
    }

    /// Removes a Drive scope only after every owner has stopped. Authentication remains valid, and a clean
    /// facade resolves or recreates the Photos volume after SDK, timeline, media, and location data is purged.
    private func recoverAfterScopeAccessLoss(
        expectedSession: ProtonSession? = nil,
        expectedLoadGeneration: Int? = nil
    ) async {
        guard let currentSession = session, let store else { return }
        scheduleScopeRecovery(
            failedSession: expectedSession ?? currentSession,
            failedStore: store,
            failedLoadGeneration: expectedLoadGeneration ?? loadToken
        )
        _ = await scopeRecoveryCoordinator.joinIfActive()
    }

    private func scopeRecoveryIsCurrent(_ identity: MobileScopeRecoveryIdentity) -> Bool {
        identity.matches(
            session: session,
            loadGeneration: loadToken,
            activeIdentity: scopeRecoveryCoordinator.activeIdentity
        )
    }

    /// Lifecycle-only platform seam. Detection cadence and failure backoff remain shared TimelineCore policy.
    func setApplicationActive(_ active: Bool) {
        applicationIsActive = active
        if active, initialLibraryLoadSettled {
            startLibraryChangeMonitorIfPossible()
        } else {
            Task { await libraryChangeMonitor.stop() }
        }
        sourceAnalysis.enqueueLifecycle { await $0.setActive(active) }
    }

    /// Copies shared photos into the account's own library and refreshes it so the copies appear. Returns `nil`
    /// when the request failed as a whole; a partial result names the photos that were not saved.
    func saveToLibrary(_ uids: [PhotoUID]) async -> PhotoLibrarySaveResult? {
        guard let backend else { return nil }
        do {
            let result = try await backend.saveToLibrary(uids)
            if !result.saved.isEmpty { refreshAfterLocalUpload() }
            return result
        } catch {
            DebugLog.log("save to library failed: \(error)")
            return nil
        }
    }

    /// Local upload completion is authoritative enough to refresh immediately; repeated signals coalesce.
    func refreshAfterLocalUpload() {
        guard let recoverySession = session, let refreshLease = currentMutationLease() else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.uploadRefreshCoordinator.request(
                refresh: { [weak self] _ in
                    guard let self else { return .cancelled }
                    return await self.performLibraryRefresh(lease: refreshLease).failureReason
                },
                observer: { [weak self] attempt in
                    guard attempt.failureReason == .scopeAccessLost else { return }
                    await self?.recoverAfterScopeAccessLoss(
                        expectedSession: recoverySession,
                        expectedLoadGeneration: refreshLease.loadToken
                    )
                }
            )
        }
    }

    /// Best-effort settings metadata refresh. A failed foreground refresh keeps the last encrypted-cache value
    /// visible instead of turning a temporary network problem into an app-level error. Library sources are not
    /// refreshed here: each activation already starts one fresh source refresh through `setApplicationActive`.
    func refreshAccountInfo() async {
        try? await facade?.refreshAccountInfo()
    }

    /// Coalesces source discovery with any active refresh. Callers use this after connectivity or
    /// catalog change signals and do not delay the primary timeline refresh on secondary metadata.
    func refreshLibrarySources() {
        loadFavoritesIfNeeded()
        guard let sourceAnalysisRuntime else { return }
        Task { await sourceAnalysisRuntime.refresh() }
    }

    /// Unknown favorites can recover through existing refresh signals without reloading the account.
    /// The task owner coalesces startup and refresh calls; known membership needs no further server read.
    private func loadFavoritesIfNeeded() {
        guard favoriteLoadTask == nil,
            favoriteFilterAvailability != .available,
            !isSigningOut, !isRecoveringScope,
            let backend, let session
        else { return }
        let loadGeneration = loadToken
        let read = favoriteState.beginLoad()
        favoriteLoadTask = Task { [weak self, backend] in
            let loaded = try? await backend.favoriteUIDs()
            guard let self,
                !Task.isCancelled,
                loadGeneration == self.loadToken,
                self.session == session
            else { return }
            self.favoriteLoadTask = nil
            self.favoriteState.finishLoad(loaded, for: read)
        }
    }

    /// Called when the grid first draws a fully populated frame to lift the loading UI.
    func markFirstContentReady() {
        apply(.firstContentReady)
    }

    private func scheduleThumbnailPrefetch(using feed: UIKitThumbnailFeed) {
        // Metadata corrections must not restart the whole-library crawl. Later new identities use the
        // existing update coordinator. An empty first inventory does not consume this generation's start.
        // Teardown and a replacement load clear this owner; completion deliberately retains it.
        guard !items.isEmpty, prefetchStartTask == nil else { return }
        let crawlItems = items
        let token = loadToken
        isThumbnailPrefetchLoading = !crawlItems.isEmpty
        prefetchStartTask = Task { [weak self] in
            let uids = await Task.detached(priority: .utility) {
                ThumbnailCrawlOrder.newestToOldestFromChronological(crawlItems)
            }.value
            guard !Task.isCancelled, token == self?.loadToken else { return }
            await feed.startPrefetch(uids)
            do {
                try await feed.waitForPrefetchToFinish()
            } catch {
                return  // A replacement task or teardown owns the current presentation state.
            }
            guard !Task.isCancelled, token == self?.loadToken else { return }
            self?.isThumbnailPrefetchLoading = false
        }
    }

    /// Reports photos that appeared since `shownBefore`. `change` comes from `applyItems`; without it, another
    /// publication replaced the timeline, and the comparison runs here against the timeline shown now.
    private func reconcileNewAssetThumbnails(
        since shownBefore: TimelineSnapshot,
        change: TimelineProjectionChange?,
        using feed: UIKitThumbnailFeed
    ) {
        let change = change ?? TimelineProjectionChange(from: shownBefore, to: snapshot, nextUIDs: items.map(\.uid))
        // The same identities leave an empty pending set empty. A pending set can still hold a photo that trash
        // removed without a reconcile, so it is reconciled against the current identities.
        guard change.identitiesChanged || thumbnailUpdateCoordinator.state.isActive else { return }
        thumbnailUpdateCoordinator.reconcile(
            currentUIDs: change.uids,
            addedUIDs: change.addedUIDs,
            onStateChange: { [weak self] state in
                self?.isNewAssetThumbnailLoading = state.isActive
            },
            resolver: { uids, enqueueMissing in
                await feed.libraryUpdateResolution(for: uids, enqueueMissing: enqueueMissing)
            }
        )
    }

    /// Starts one resumable, low-priority GPS crawl when the Map first opens.
    func startLocationCrawlIfNeeded() {
        guard
            MapAndPlacesPolicy.allowsLocationCrawl(
                enabled: MapAndPlacesPolicy.isEnabled(), itemCount: items.count),
            !locationCrawlStarted, let backend, let cacheContext
        else { return }
        locationCrawlStarted = true
        locationCrawlGeneration &+= 1
        let crawlGeneration = locationCrawlGeneration
        let loadGeneration = loadToken
        let accountUID = cacheContext.accountUID
        let previousStarter = locationCrawlStartTask
        let previousPrivacyStop = locationPrivacyStopTask
        previousStarter?.cancel()

        // Reuse the latest off-actor projection when available. The fallback covers tests or an early Map open.
        let initialItems = items
        let inventoryTask =
            locationInventoryTask
            ?? Task.detached(priority: .utility) {
                LocationCrawlInventory(items: initialItems)
            }
        locationInventoryTask = inventoryTask
        locationCrawlInventoryRevision = locationInventoryRevision
        let index = locationIndex
        let store = locationStore
        let crawl = locationCrawl
        let feed = thumbnailFeed
        let governor = LibraryWorkloadGovernorPolicy()
        locationCrawlStartTask = Task { @MainActor [weak self, previousStarter, previousPrivacyStop] in
            await previousPrivacyStop?.value
            await previousStarter?.value
            guard let self,
                !Task.isCancelled,
                crawlGeneration == self.locationCrawlGeneration,
                loadGeneration == self.loadToken,
                self.session?.uid == accountUID,
                MapAndPlacesPolicy.isEnabled()
            else { return }
            // Startup already restored the account's location cache. Map entry only resumes its crawl.
            await crawl.cancel()
            guard !Task.isCancelled,
                crawlGeneration == self.locationCrawlGeneration,
                loadGeneration == self.loadToken,
                self.session?.uid == accountUID,
                MapAndPlacesPolicy.isEnabled()
            else { return }
            guard let sessionLease = store.captureSessionLease() else { return }
            let initialInventory = await inventoryTask.value
            guard !Task.isCancelled,
                crawlGeneration == self.locationCrawlGeneration,
                loadGeneration == self.loadToken,
                self.session?.uid == accountUID,
                MapAndPlacesPolicy.isEnabled()
            else { return }
            // Give thumbnail crawling a head start, then yield to visible demand. Do not use
            // `hasPendingThumbnailWork()` because it includes whole-library fill and can starve map indexing.
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard !Task.isCancelled,
                store.isCurrentSessionLease(sessionLease),
                crawlGeneration == self.locationCrawlGeneration,
                loadGeneration == self.loadToken,
                self.session?.uid == accountUID,
                MapAndPlacesPolicy.isEnabled()
            else { return }
            await crawl.start(
                uids: initialInventory.uids,
                captureDates: initialInventory.captureDates,
                accountUID: accountUID,
                location: LocationCrawl.metadataProbe(backend),
                index: index,
                store: store,
                shouldYield: {
                    let applicationIsActive = await MainActor.run { self.applicationIsActive }
                    guard applicationIsActive else { return true }
                    let visibleDemand = await feed?.hasVisibleThumbnailPressure() ?? false
                    return governor.budget(
                        for: .backgroundLocationCrawl,
                        signals: LibraryWorkloadSignals(hasVisibleMediaDemand: visibleDemand)
                    ).shouldYield
                },
                log: { DebugLog.log($0) },
                inventory: { @MainActor [weak self] in
                    guard let self, let task = self.locationInventoryTask else {
                        return LocationCrawlInventory()
                    }
                    let revision = self.locationInventoryRevision
                    let inventory = await task.value
                    self.locationCrawlInventoryRevision = max(
                        self.locationCrawlInventoryRevision,
                        revision
                    )
                    return inventory
                }
            )
            guard !Task.isCancelled,
                crawlGeneration == self.locationCrawlGeneration,
                loadGeneration == self.loadToken,
                self.session?.uid == accountUID
            else {
                await crawl.cancel()
                return
            }
            if self.locationCrawlInventoryRevision != self.locationInventoryRevision {
                self.locationCrawlStarted = false
                self.startLocationCrawlIfNeeded()
            }
        }
    }

    func pauseMapAndPlaces() {
        mapPrewarmer.cancel()
        locationCrawlGeneration &+= 1
        locationCrawlStarted = false
        locationCrawlStartTask?.cancel()
        let previousStop = locationPrivacyStopTask
        let crawl = locationCrawl
        locationPrivacyStopTask = Task {
            await previousStop?.value
            await crawl.cancel()
        }
    }

    func resumeMapAndPlaces() {
        guard MapAndPlacesPolicy.isEnabled() else { return }
        mapPrewarmer.prewarm(coordinates: locationIndex.coordinates)
        startLocationCrawlIfNeeded()
    }

    func restartLocationCrawlIfNeeded() {
        guard !items.isEmpty else { return }
        locationCrawlStarted = false
        startLocationCrawlIfNeeded()
    }

    /// Builds the account-scoped Smart Search lifecycle. MLSearchCore owns lifecycle decisions.
    private func configureSmartSearch(session: ProtonSession, client: ProtonClientFacade, feed: UIKitThumbnailFeed) {
        guard AppleSmartSearchBootstrap.featureAvailability() == .available else {
            searchSuggestions.reset()
            smartSearchSession.stop()
            return
        }
        // iOS rebuilds the lifecycle on every library load; the assets universe restarts hydration first.
        smartSearchSession.assets.beginHydration()
        smartSearchSession.configure(
            accountDirectory: client.accountDataDirectory,
            accountUID: session.uid,
            keyPassword: session.keyPassword,
            feed: feed.feedCore,
            databasePolicy: client.accountDatabasePolicy
        )
    }

    private func configureSourceAnalysis(client: ProtonClientFacade, feed: UIKitThumbnailFeed) {
        guard sourceAnalysisRuntime == nil else { return }
        let runtime = LibrarySourceAnalysisRuntime(
            coordinator: client.librarySources,
            feed: feed.feedCore,
            assets: smartSearchAssets,
            initiallyActive: applicationIsActive,
            onAssetsChanged: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.sourceAnalysisRevision &+= 1
                    self.smartSearch?.noteLibraryChanged()
                }
            }
        )
        sourceAnalysis.install(runtime)
    }

    /// Installs the source-aware byte route before the same primary inventory is exposed to the grid. Otherwise
    /// the first visible warm pass can run against the runtime's initial empty scope and leave the loading cover
    /// without a rendered thumbnail with which to settle.
    private func synchronizePrimarySourceInventory(
        _ items: [PhotoItem],
        authority: SourceInventoryAuthority
    ) async -> PrimaryInventoryAdmission {
        await sourceAnalysis.synchronizePrimaryInventory(items, authority: authority)
    }

    @discardableResult
    private func stopSourceAnalysis() -> Task<Void, Never>? {
        smartSearchAssets.invalidateSourceSession()
        return sourceAnalysis.stop()
    }

    /// Retires transient retry owners without deleting account data. Every replacement load waits for this
    /// barrier, so a retry never opens a second owner graph while the previous graph still owns SQLite handles.
    private func retireForRetry(advanceLoadToken: Bool = true) async {
        let previousTeardown = teardownTask
        let activeFacade = facade
        let activeLoadTask = loadTask
        let activeTransitionTask = transitionTask
        let activePrefetchStartTask = prefetchStartTask
        let activeFavoriteLoadTask = favoriteLoadTask
        let activePhotoBackup = photoBackup
        let activePendingGrid = retirePendingGrid()
        let activeAlbumSync = albumSync
        let activeThumbnailFeed = thumbnailFeed
        let activeRefreshCoalescer = libraryRefreshCoalescer
        let activeUploadRefreshCoordinator = uploadRefreshCoordinator
        let activeChangeMonitor = libraryChangeMonitor
        let activeLocationCrawl = locationCrawl
        let activeLocationCrawlStarter = locationCrawlStartTask
        searchSuggestions.reset()
        let smartSearchShutdown = smartSearchSession.stop()
        let sourceAnalysisShutdown = stopSourceAnalysis()

        if advanceLoadToken { loadToken &+= 1 }
        activeLoadTask?.cancel()
        loadTask = nil
        transitionTask?.cancel()
        transitionTask = nil
        prefetchStartTask?.cancel()
        prefetchStartTask = nil
        isThumbnailPrefetchLoading = false
        favoriteLoadTask?.cancel()
        favoriteLoadTask = nil
        seriesDissolutionTask?.cancel()
        seriesDissolutionTask = nil
        favoriteState.reset(keepingFavorites: true)
        let activeThumbnailUpdateTask = thumbnailUpdateCoordinator.cancel()
        locationCrawlGeneration &+= 1
        activeLocationCrawlStarter?.cancel()
        locationCrawlStartTask = nil
        locationCrawlStarted = false
        locationInventoryTask?.cancel()
        locationInventoryTask = nil
        isRefreshingLibrary = false
        initialLibraryLoadSettled = false
        primaryInventoryAuthority = .hydrating
        backend = nil
        facade = nil
        albumActions = nil
        PhotoBackupBackgroundCoordinator.shared.backupStopped()
        photoBackup = nil
        albumSync = nil
        thumbnailFeed = nil

        let coordinator: AccountTeardownCoordinator
        do {
            coordinator = try MobileRetryOwnerGraph.makeCoordinator(
                platformTasks: {
                    await previousTeardown?.value
                    await activeTransitionTask?.value
                    await activeLoadTask?.value
                    await activePrefetchStartTask?.value
                    await activeFavoriteLoadTask?.value
                    await activeThumbnailUpdateTask?.value
                    await activeRefreshCoalescer.cancel()
                    await activeUploadRefreshCoordinator.cancel()
                    await activeChangeMonitor.reset()
                    await activeThumbnailFeed?.stopPrefetch()
                },
                smartSearch: {
                    await smartSearchShutdown?.value
                    await sourceAnalysisShutdown?.value
                },
                locationCrawl: {
                    await activeLocationCrawlStarter?.value
                    await activeLocationCrawl.cancel()
                },
                photoBackup: {
                    await activePendingGrid.session?.close()
                    await activePhotoBackup?.shutdown()
                    activePendingGrid.store?.close()
                },
                albumSync: {
                    await activeAlbumSync?.shutdown()
                },
                facade: {
                    await activeFacade?.shutdown()
                }
            )
        } catch {
            preconditionFailure("Duplicate transient retry owner identifier")
        }
        _ = await coordinator.teardown()
    }

    private func teardown() {
        LibraryRuntimeState.shared.beginNewGeneration()
        let previousTeardown = teardownTask
        let activeFacade = facade
        let activeLoadTask = loadTask
        let activeTransitionTask = transitionTask
        let activePrefetchStartTask = prefetchStartTask
        let activeFavoriteLoadTask = favoriteLoadTask
        let purgeClaim = BackupLocalDataPurge.claimSignOutPurge()
        isSigningOut = purgeClaim != nil
        pendingSignOutPurgeClaim = purgeClaim
        signOutCleanupFailed = false
        let activePhotoBackup = photoBackup
        let activePendingGrid = retirePendingGrid()
        let activeAlbumSync = albumSync
        let activeThumbnailFeed = thumbnailFeed
        let activeOriginalsCache = originalsCache
        let activeRefreshCoalescer = libraryRefreshCoalescer
        let activeUploadRefreshCoordinator = uploadRefreshCoordinator
        let activeChangeMonitor = libraryChangeMonitor
        let activeLocationCrawl = locationCrawl
        let activeLocationCrawlStarter = locationCrawlStartTask
        let activeLocationIndex = locationIndex
        let activeRetry = retryTask
        let activeScopeRecovery = scopeRecoveryCoordinator.cancel()

        loadToken &+= 1  // supersede any in-flight snapshot sort
        activeRetry?.cancel()
        retryTask = nil
        isRecoveringScope = false
        activeLoadTask?.cancel()
        loadTask = nil
        transitionTask?.cancel()
        transitionTask = nil
        prefetchStartTask?.cancel()
        prefetchStartTask = nil
        isThumbnailPrefetchLoading = false
        favoriteLoadTask?.cancel()
        favoriteLoadTask = nil
        favoriteState.reset(keepingFavorites: true)
        let activeThumbnailUpdateTask = thumbnailUpdateCoordinator.cancel()
        isRefreshingLibrary = false
        initialLibraryLoadSettled = false
        primaryInventoryAuthority = .hydrating
        configuredUID = nil
        session = nil
        cacheContext = nil
        backend = nil
        facade = nil
        albumActions = nil
        PhotoBackupBackgroundCoordinator.shared.backupStopped()
        photoBackup = nil
        albumSync = nil
        albumCatalogRevision = 0
        timelineRemovals = TimelineRemovalOverlay()
        timelineMutationGeneration &+= 1
        snapshot = TimelineSnapshot()
        sections = []
        favoriteState.reset(keepingFavorites: false)
        timelineRevision &+= 1
        thumbnailFeed = nil
        searchSuggestions.reset()
        let smartSearchShutdown = smartSearchSession.stop()
        let sourceAnalysisShutdown = stopSourceAnalysis()
        thumbnailCache = nil
        originalsCache = nil
        loadState = .initial
        locationCrawlStarted = false
        locationInventoryTask?.cancel()
        locationInventoryTask = nil
        locationIndex.replaceAll([])
        locationIndex.updateScanProgress(PhotoLocationScanProgress())
        var teardownOwners = [
            AccountTeardownOwner(id: "mobile.platform-tasks", stage: .platformTasks) {
                await previousTeardown?.value
                await activeRetry?.value
                await activeScopeRecovery?.value
                await activeTransitionTask?.value
                await activeLoadTask?.value
                await activePrefetchStartTask?.value
                await activeFavoriteLoadTask?.value
                await activeThumbnailUpdateTask?.value
                await activeRefreshCoalescer.cancel()
                await activeUploadRefreshCoordinator.cancel()
                await activeChangeMonitor.reset()
                await activeThumbnailFeed?.stopPrefetch()
            },
            AccountTeardownOwner(id: "shared.smart-search", stage: .smartSearch) {
                await smartSearchShutdown?.value
                await sourceAnalysisShutdown?.value
            },
            AccountTeardownOwner(id: "mobile.location-crawl", stage: .locationCrawl) {
                await activeLocationCrawlStarter?.value
                await activeLocationCrawl.cancel()
                activeLocationIndex.replaceAll([])
                activeLocationIndex.updateScanProgress(PhotoLocationScanProgress())
            },
            AccountTeardownOwner(id: "shared.photo-backup", stage: .photoBackup) {
                await activePendingGrid.session?.close()
                await activePhotoBackup?.shutdown()
                // The purge deletes the account directory; the pending store must be closed first.
                activePendingGrid.store?.close()
            },
            AccountTeardownOwner(id: "shared.album-sync", stage: .albumSync) {
                await activeAlbumSync?.shutdown()
            },
            AccountTeardownOwner(id: "shared.proton-facade", stage: .facade) {
                await activeFacade?.shutdown()
            },
            AccountTeardownOwner(id: "mobile.originals-cache", stage: .caches) {
                guard let activeOriginalsCache else { return }
                await Task.detached(priority: .utility) {
                    activeOriginalsCache.clearForSignOut()
                }.value
            },
            AccountTeardownOwner(id: "shared.debug-log", stage: .logs) {
                await DebugLog.flush()
            },
        ]
        // Transient teardown must not delete account data. Only a claimed sign-out purge may do so.
        if let purgeClaim {
            teardownOwners.append(
                AccountTeardownOwner(id: "shared.local-data-claim", stage: .purgeClaims) {
                    PendingReplacementLedger.clearForSignOut()
                    let succeeded = await ProtonAuthLocalDataPurge.performOffMain(claim: purgeClaim)
                    guard succeeded else { throw TeardownFailure.purgeFailed }
                }
            )
        }

        let teardownCoordinator: AccountTeardownCoordinator
        do {
            teardownCoordinator = try AccountTeardownCoordinator(owners: teardownOwners)
        } catch {
            preconditionFailure("Duplicate account teardown owner identifier")
        }
        teardownTask = Task { @MainActor in
            let report = await teardownCoordinator.teardown()
            guard purgeClaim != nil else { return }
            if report.succeeded {
                self.pendingSignOutPurgeClaim = nil
                self.isSigningOut = false
            } else {
                self.signOutCleanupFailed = true
            }
        }
    }

    /// Retries only the idempotent purge. The first teardown already joined every account-scoped owner.
    /// A failed retry keeps the durable marker and returns to the finite error presentation.
    func retrySignOutCleanup() {
        guard signOutCleanupFailed, let claim = pendingSignOutPurgeClaim else { return }
        signOutCleanupFailed = false
        teardownTask = Task { @MainActor in
            let succeeded = await ProtonAuthLocalDataPurge.performOffMain(claim: claim)
            if succeeded {
                self.pendingSignOutPurgeClaim = nil
                self.isSigningOut = false
            } else {
                self.signOutCleanupFailed = true
            }
        }
    }

    private func start(
        session: ProtonSession,
        store: SessionKeychainStore,
        preserveVisibleSnapshot: Bool = false
    ) {
        LibraryRuntimeState.shared.beginNewGeneration()
        isSigningOut = false
        signOutCleanupFailed = false
        pendingSignOutPurgeClaim = nil
        loadToken &+= 1  // this load supersedes any older in-flight snapshot sort
        let loadGeneration = loadToken
        loadTask?.cancel()
        prefetchStartTask?.cancel()
        prefetchStartTask = nil
        isThumbnailPrefetchLoading = false
        favoriteLoadTask?.cancel()
        favoriteLoadTask = nil
        favoriteState.reset(keepingFavorites: preserveVisibleSnapshot)
        thumbnailUpdateCoordinator.cancel()
        isRefreshingLibrary = false
        initialLibraryLoadSettled = false
        primaryInventoryAuthority = .hydrating
        configuredUID = session.uid
        backend = nil
        facade = nil
        albumActions = nil
        photoBackup = nil
        _ = retirePendingGrid()
        albumSync = nil
        timelineRemovals = TimelineRemovalOverlay()
        timelineMutationGeneration &+= 1
        if !preserveVisibleSnapshot {
            snapshot = TimelineSnapshot()
            sections = []
            timelineRevision &+= 1
        }
        thumbnailFeed = nil
        searchSuggestions.reset()
        smartSearchSession.stop()
        stopSourceAnalysis()
        loadState = .preparingInventory

        let cacheContext = LocalMediaCacheContext(accountUID: session.uid, keyPassword: session.keyPassword)
        self.cacheContext = cacheContext
        let cache = ThumbnailCache(
            namespace: "mobile-thumbnails",
            derivative: "thumbnail",
            configuration: UIKitMediaCachePolicy.thumbnailByteCacheConfiguration()
        )
        thumbnailCache = cache

        // Separate encrypted store for decrypted originals, keyed to the account and isolated from thumbnails.
        // The viewer seeds it; share and export reuse it.
        let originals = ThumbnailCache(namespace: "mobile-originals", derivative: "original")
        cacheContext.configure(cache, originals)
        let originalsCap = originalsCacheCapBytes
        Task.detached(priority: .utility) {
            originals.enforceByteCap(originalsCap)
        }
        originalsCache = originals

        // Register UIKit pressure and lifecycle signals with the shared governor. Cache registrations are
        // identity-keyed, so a new session replaces the previous cache and feed.
        UIKitMemoryPressureCoordinator.shared.install()
        UIKitMemoryPressureCoordinator.shared.attachByteCache(cache)

        loadTask = Task { [weak self] in
            guard let self else { return }
            var hadCachedInventory = false
            do {
                // Suggestions validate locations as part of their content identity. Restore the existing
                // encrypted store before publishing settled inventory, even if Map is never opened.
                // This reads local data only; it does not start the GPS crawl or geocoding.
                let locationStore = self.locationStore
                let locationLease = locationStore.configure(
                    accountUID: cacheContext.accountUID, key: cacheContext.encryptionKey)
                let savedLocations = await Task.detached(priority: .utility) {
                    locationStore.loadSnapshot()
                }.value
                guard !Task.isCancelled, loadGeneration == self.loadToken, self.session == session,
                    locationStore.isCurrentSessionLease(locationLease)
                else { return }
                self.locationIndex.replaceAll(savedLocations)
                // Map tiles come from Apple, so this runs only where the Map was opened before.
                self.mapPrewarmer.prewarm(coordinates: self.locationIndex.coordinates)
                let client = try await ProtonDriveBackendFactory.makeFacade(
                    session: session,
                    store: store,
                    policy: .standard(
                        libraryDatabasePolicy: ProtonDriveBackendPolicy.mobileLibraryDatabasePolicy,
                        videoCacheBudgetBytes: 128 * 1024 * 1024
                    )
                )
                guard !Task.isCancelled,
                    loadGeneration == self.loadToken,
                    self.session == session
                else {
                    await client.shutdown()
                    return
                }
                let backend = client.backend
                let feed = UIKitThumbnailFeed(
                    cache: cache,
                    loader: client.librarySources,
                    dimensions: PhotoDimensionCoalescer(store: backend),
                    targetPixels: 288
                )
                let pendingStore = PendingGridSession.openStore(
                    accountDataDirectory: client.accountDataDirectory,
                    policy: client.accountDatabasePolicy
                )
                let photoBackup = PhotoLibraryBackupController(
                    configuration: .init(
                        accountDataDirectory: client.accountDataDirectory,
                        databasePolicy: client.accountDatabasePolicy
                    ),
                    identityResolver: client.uploadIdentityResolver,
                    uploader: client.photoUploader,
                    tagAdder: client.photoTagAdder,
                    editReplacement: client.editedPhotoReplacement,
                    pendingStore: pendingStore,
                    requiresPendingStore: true
                )
                let albumSync = AlbumSyncController(
                    configuration: .init(
                        accountDataDirectory: client.accountDataDirectory,
                        databasePolicy: client.accountDatabasePolicy
                    ),
                    identityResolver: client.uploadIdentityResolver,
                    uploader: client.photoUploader,
                    remoteOps: client.albumSyncRemoteOps
                )
                albumSync.setRemoteAlbumsChangedHandler { [weak self] in
                    guard let self,
                        loadGeneration == self.loadToken,
                        self.session == session
                    else { return }
                    self.albumCatalogRevision &+= 1
                }
                await client.uploadCoordinator.start()
                guard !Task.isCancelled,
                    loadGeneration == self.loadToken,
                    self.session == session
                else {
                    await photoBackup.shutdown()
                    pendingStore?.close()
                    await albumSync.shutdown()
                    await client.shutdown()
                    return
                }
                self.facade = client
                if let seriesDissolution = client.seriesDissolution {
                    self.seriesDissolutionTask?.cancel()
                    self.seriesDissolutionTask = Task(priority: .utility) { [weak self] in
                        await self?.resumePendingSeriesDissolutions(seriesDissolution)
                    }
                }
                self.albumActions = AlbumActionCoordinator(repository: client.albums)
                self.photoBackup = photoBackup
                PhotoBackupBackgroundCoordinator.shared.configure(controller: photoBackup)
                self.albumSync = albumSync
                self.backend = backend
                self.thumbnailFeed = feed
                self.configurePendingGrid(store: pendingStore, photoBackup: photoBackup, client: client, feed: feed)
                if self.isRecoveringScope {
                    self.isRecoveringScope = false
                }
                self.loadFavoritesIfNeeded()
                // The live feed's RAM tiers (UIImage wrappers + decoded core) respond to pressure tiers.
                UIKitMemoryPressureCoordinator.shared.attachFeed(feed)
                self.configureSourceAnalysis(client: client, feed: feed)
                self.configureSmartSearch(session: session, client: client, feed: feed)
                // Show the persisted snapshot while Core validates its event token. A match avoids row
                // enumeration; a mismatch falls back to the authoritative load.
                var cacheValidation = TimelineCacheValidation.refreshRequired(monitorBaseline: nil)
                if let cached = await backend.cachedTimelineSnapshot() {
                    hadCachedInventory = true
                    guard !Task.isCancelled,
                        loadGeneration == self.loadToken,
                        self.session == session
                    else { return }
                    try await applyItems(cached.sections, cached: true)
                    guard !Task.isCancelled,
                        loadGeneration == self.loadToken,
                        self.session == session
                    else { return }
                    scheduleThumbnailPrefetch(using: feed)
                    cacheValidation = await TimelineCacheValidationPolicy.validate(
                        snapshot: cached,
                        repository: backend
                    )
                    guard !Task.isCancelled,
                        loadGeneration == self.loadToken,
                        self.session == session
                    else { return }
                    if case .terminalFailure = cacheValidation {
                        throw TimelineCacheValidationTerminalError()
                    }
                    if case .validated(let token) = cacheValidation {
                        publishSmartSearchInventory(
                            snapshot.items,
                            authority: .authoritative
                        )
                        apply(.authoritativeInventoryResolved(count: items.count, requiresNewFrame: false))
                        initialLibraryLoadSettled = true
                        startLibraryChangeMonitorIfPossible(
                            resetBaseline: true,
                            initialToken: token
                        )
                        return
                    }
                }

                let refreshed = try await backend.loadTimelineSnapshot()
                guard !Task.isCancelled,
                    loadGeneration == self.loadToken,
                    self.session == session
                else { return }
                let shownBefore = snapshot
                let change = try await applyItems(refreshed.sections, cached: false, authoritative: true)
                guard !Task.isCancelled,
                    loadGeneration == self.loadToken,
                    self.session == session
                else { return }
                scheduleThumbnailPrefetch(using: feed)
                if hadCachedInventory {
                    reconcileNewAssetThumbnails(since: shownBefore, change: change, using: feed)
                }
                initialLibraryLoadSettled = true
                self.startLibraryChangeMonitorIfPossible(
                    resetBaseline: true,
                    initialToken: refreshed.validationToken ?? cacheValidation.monitorBaseline
                )
            } catch is CancellationError {
                // A newer session/configuration replaced this task.
            } catch let error as any LibraryChangeTerminalError {
                guard loadGeneration == self.loadToken, self.session == session else { return }
                DebugLog.log("timeline: terminal scope failure during initial load - \(error)")
                // The recovery task must not join the load task that schedules it. Remove this completed owner
                // first, then synchronously register recovery before this main-actor turn ends.
                self.loadTask = nil
                self.scheduleScopeRecovery(
                    failedSession: session,
                    failedStore: store,
                    failedLoadGeneration: loadGeneration
                )
            } catch {
                guard loadGeneration == self.loadToken, self.session == session else { return }
                if self.isRecoveringScope {
                    self.isRecoveringScope = false
                }
                if error is SourceAnalysisStartupError {
                    apply(.contentLoadFailed(message: Self.message(for: error)))
                } else {
                    apply(.failed(message: Self.message(for: error), retryable: true))
                }
                initialLibraryLoadSettled = true
                // Both cold and cached loads must recover when the server becomes reachable again, even if
                // its revision did not change. An unknown (nil) baseline would only observe that revision.
                startLibraryChangeMonitorIfPossible(resetBaseline: true, initialToken: "")
            }
        }
    }

    /// Builds an immutable `TimelineSnapshot` off the main actor and publishes it only for the current load.
    /// It compares the new timeline with the shown one off the main actor too, and returns that comparison.
    /// Nil means that a cancelled or superseded load published nothing.
    @discardableResult
    private func applyItems(
        _ sections: [TimelineSection],
        cached: Bool,
        authoritative: Bool = false
    ) async throws -> TimelineProjectionChange? {
        let token = loadToken
        let mutationGeneration = timelineMutationGeneration
        let removals = timelineRemovals.hiddenFromLibrary
        let shown = snapshot
        let shownRevision = timelineRevision
        let (prepared, preparedChange) = await Task.detached(priority: .userInitiated) {
            let projection = TimelineContentProjection(sections: sections).removing(removals)
            return (projection, TimelineProjectionChange(from: shown, to: projection))
        }.value
        // The generation token rejects results from cancelled or superseded loads.
        guard !Task.isCancelled,
            token == loadToken,
            mutationGeneration == timelineMutationGeneration
        else { return nil }
        let sourceReady = await synchronizePrimarySourceInventory(
            prepared.snapshot.items,
            authority: authoritative ? .authoritative : .cached
        )
        try Task.checkCancellation()
        guard token == loadToken,
            mutationGeneration == timelineMutationGeneration
        else { return nil }
        if sourceReady == .superseded { return nil }
        guard sourceReady == .accepted else { throw SourceAnalysisStartupError() }
        // A concurrent load can publish while this one waits; then compare with the timeline shown now.
        let change =
            timelineRevision == shownRevision ? preparedChange : TimelineProjectionChange(from: snapshot, to: prepared)
        let requiresNewFrame = change.identitiesChanged
        let changed = change.contentChanged
        if authoritative {
            primaryInventoryAuthority = .authoritative
        } else if cached, primaryInventoryAuthority != .authoritative {
            primaryInventoryAuthority = .cached
        }
        if changed {
            publish(
                prepared,
                locationInventoryChanged: requiresNewFrame,
                publishPrimaryInventory: false
            )
        }
        if authoritative {
            apply(
                .authoritativeInventoryResolved(
                    count: prepared.snapshot.count,
                    requiresNewFrame: requiresNewFrame
                ))
        } else {
            apply(.inventoryResolved(count: prepared.snapshot.count, cached: cached))
        }
        return change
    }

    private func publish(
        _ projection: TimelineContentProjection,
        locationInventoryChanged: Bool,
        publishPrimaryInventory: Bool = true
    ) {
        if locationInventoryChanged {
            let locationItems = projection.snapshot.items
            locationInventoryTask?.cancel()
            locationInventoryTask = Task.detached(priority: .utility) {
                LocationCrawlInventory(items: locationItems)
            }
        }
        snapshot = projection.snapshot
        sections = projection.sections
        timelineRevision &+= 1
        if locationInventoryChanged {
            locationInventoryRevision &+= 1
        }
        if publishPrimaryInventory {
            publishSmartSearchInventory(projection.snapshot.items)
        }
        if locationCrawlStarted,
            locationCrawlInventoryRevision != locationInventoryRevision,
            locationIndex.scanProgress.phase == .completed || locationIndex.scanProgress.phase == .failed
        {
            locationCrawlStarted = false
            startLocationCrawlIfNeeded()
        }
    }

    private func publishSmartSearchInventory(
        _ items: [PhotoItem],
        authority: SourceInventoryAuthority? = nil
    ) {
        if let authority,
            primaryInventoryAuthority != .authoritative || authority == .authoritative
        {
            primaryInventoryAuthority = authority
        }
        sourceAnalysis.replacePrimaryInventory(
            items,
            authority: primaryInventoryAuthority,
            onFailure: { [weak self] in
                self?.apply(.contentLoadFailed(message: L10n.string("error.load_library_title")))
            }
        )
    }

    private func startLibraryChangeMonitorIfPossible(
        resetBaseline: Bool = false,
        initialToken: String? = nil
    ) {
        guard applicationIsActive,
            initialLibraryLoadSettled,
            let provider = backend as? any LibraryChangeTokenProvider,
            let recoverySession = session,
            let refreshLease = currentMutationLease()
        else { return }
        // A failed cold load may have settled while inactive. Preserve its retry seed on the next foreground
        // start; otherwise that start would silently establish a baseline without ever loading the inventory.
        let initialToken = initialToken ?? (loadState.failure?.retryable == true ? "" : nil)
        Task { [weak self] in
            guard let self,
                !self.isRecoveringScope,
                refreshLease.isCurrent(loadToken: self.loadToken, sessionUID: self.session?.uid)
            else { return }
            await self.libraryChangeMonitor.restart(
                provider: provider,
                resetBaseline: resetBaseline,
                initialToken: initialToken,
                onTerminal: { [weak self] _ in
                    await self?.recoverAfterScopeAccessLoss(
                        expectedSession: recoverySession,
                        expectedLoadGeneration: refreshLease.loadToken
                    )
                },
                onChange: { [weak self] in
                    guard let self else { return .retry }
                    return await self.libraryRefreshCoalescer.request { [weak self] in
                        await self?.performLibraryRefresh(lease: refreshLease).outcome ?? .retry
                    }
                }
            )
        }
    }

    private func requestLibraryRefresh() {
        guard let recoverySession = session, let refreshLease = currentMutationLease() else { return }
        let coalescer = libraryRefreshCoalescer
        Task { [weak self] in
            let outcome = await coalescer.request { [weak self] in
                await self?.performLibraryRefresh(lease: refreshLease).outcome ?? .retry
            }
            if outcome == .terminal {
                await self?.recoverAfterScopeAccessLoss(
                    expectedSession: recoverySession,
                    expectedLoadGeneration: refreshLease.loadToken
                )
            }
        }
    }

    private func performLibraryRefresh(
        lease refreshLease: MobileLibraryMutationLease
    ) async -> MobileLibraryRefreshResult {
        guard !isRecoveringScope,
            refreshLease.isCurrent(loadToken: loadToken, sessionUID: session?.uid),
            let backend
        else { return .init(outcome: .retry, failureReason: .cancelled) }
        isRefreshingLibrary = true
        defer { isRefreshingLibrary = false }
        do {
            let refreshed = try await backend.loadTimeline()
            try Task.checkCancellation()
            try requireCurrentMutation(refreshLease)
            let shownBefore = snapshot
            let change = try await applyItems(refreshed, cached: false, authoritative: true)
            try requireCurrentMutation(refreshLease)
            if let thumbnailFeed {
                scheduleThumbnailPrefetch(using: thumbnailFeed)
                reconcileNewAssetThumbnails(since: shownBefore, change: change, using: thumbnailFeed)
            }
            // The same opaque server event token covers album mutations. Reuse this central foreground
            // refresh instead of adding a second poller; Collections reloads through its existing revision key.
            albumCatalogRevision &+= 1
            refreshLibrarySources()
            return .init(outcome: .refreshed, failureReason: nil)
        } catch is CancellationError {
            return .init(outcome: .retry, failureReason: .cancelled)
        } catch is any LibraryChangeTerminalError {
            return .init(outcome: .terminal, failureReason: .scopeAccessLost)
        } catch is any TimelineInventoryConvergenceError {
            return .init(outcome: .retry, failureReason: .pendingInventoryVisibility)
        } catch {
            DebugLog.log("timeline: foreground refresh failed - \(error)")
            return .init(outcome: .retry, failureReason: .other)
        }
    }

    private func apply(_ event: LibraryLoadEvent) {
        loadState = LibraryLoadPolicy.reduce(loadState, event)
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

#if DEBUG
    // MARK: - Isolated fixture (hosted tests only)

    extension MobileLibraryModel {
        /// Installs a deterministic, already loaded account into this model without any network or keychain
        /// access. The production composition above it (scene roots, tab shell, timeline screens, grids, viewer)
        /// is untouched; only the account backend and its content are replaced by the given values.
        ///
        /// `configure(session:store:)` for the same session becomes a no-op because the account is already
        /// configured, and `configure(session: nil, …)` runs the ordinary ordered teardown. Debug builds only.
        func installIsolatedLibrary(
            session: ProtonSession,
            store: SessionKeychainStore,
            backend: any PhotosBackend,
            sections: [TimelineSection],
            thumbnailFeed: UIKitThumbnailFeed,
            thumbnailCache: ThumbnailCache? = nil,
            albums: AlbumsRepository? = nil
        ) {
            let projection = TimelineContentProjection(sections: sections)
            albumActions = albums.map(AlbumActionCoordinator.init(repository:))
            self.store = store
            self.session = session
            configuredUID = session.uid
            self.backend = backend
            self.thumbnailFeed = thumbnailFeed
            self.thumbnailCache = thumbnailCache
            snapshot = projection.snapshot
            self.sections = projection.sections
            // Unread favorites, so the first library refresh reads them like a signed-in account.
            favoriteState.reset(keepingFavorites: false)
            timelineRevision &+= 1
            loadState = .contentReady(count: projection.snapshot.items.count)
        }

        func installIsolatedDuplicatesForTesting(_ finder: any ExactDuplicateMerging) {
            duplicates = makeDuplicatesModel(finder)
        }

        /// Stands for an initial library load that runs until `load` returns and settles then.
        func installIsolatedInitialLoadForTesting(_ load: @escaping @MainActor () async -> Void) {
            initialLibraryLoadSettled = false
            loadTask = Task { [weak self] in
                await load()
                self?.initialLibraryLoadSettled = true
            }
        }

        func installIsolatedBackupForTesting(_ controller: PhotoLibraryBackupController) {
            photoBackup = controller
        }

        func installIsolatedAlbumSyncForTesting(_ controller: AlbumSyncController) {
            albumSync = controller
        }

        /// Installs the real source runtime for bound-feed lifecycle regression tests.
        func installIsolatedSourceAnalysisForTests(_ runtime: LibrarySourceAnalysisRuntime) {
            sourceAnalysis.install(runtime)
            primaryInventoryAuthority = .authoritative
        }

        /// Drives the production startup and new-identity paths without opening a real account backend.
        func replaceIsolatedThumbnailInventoryForTests(_ sections: [TimelineSection]) {
            let shownBefore = snapshot
            let projection = TimelineContentProjection(sections: sections)
            snapshot = projection.snapshot
            self.sections = projection.sections
            timelineRevision &+= 1
            guard let thumbnailFeed else { return }
            scheduleThumbnailPrefetch(using: thumbnailFeed)
            reconcileNewAssetThumbnails(
                since: shownBefore, change: TimelineProjectionChange(from: shownBefore, to: projection),
                using: thumbnailFeed)
        }

        func startIsolatedThumbnailPrefetchForTests() {
            guard let thumbnailFeed else { return }
            scheduleThumbnailPrefetch(using: thumbnailFeed)
        }
    }
#endif
