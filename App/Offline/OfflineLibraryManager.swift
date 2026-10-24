import Foundation
import MapFeature
import MediaByteCache
import MediaCache
import MediaLocationCore
import Observation
import PhotosCore
import ProtonAuth
import ProtonDriveBackend
import TimelineCore

/// Owns the local offline-cache roots and bridges the Settings window to the running thumbnail feed.
/// The thumbnail crawl is mandatory grid infrastructure and is independent from the Offline Library toggle.
@MainActor
@Observable
final class OfflineLibraryManager {
    static let shared = OfflineLibraryManager()

    /// Disk thumbnail cache (decoded grid previews) - shared with `MainView`'s `ThumbnailFeed`. Encrypted
    /// per-account (AES-GCM); `configure(session:)` installs a key derived from the restored Proton session.
    let cache = ThumbnailCache(
        namespace: "thumbnails",
        derivative: "thumbnail",
        configuration: MacMediaCachePolicy.thumbnailByteCacheConfiguration()
    )
    /// Larger display-preview derivatives, persisted when the viewer fetches them. Also encrypted.
    let previewCache = ThumbnailCache(
        namespace: "previews",
        derivative: "preview",
        configuration: MacMediaCachePolicy.thumbnailByteCacheConfiguration()
    )
    /// Full-resolution originals viewed in the photo viewer, persisted encrypted when the Offline Library is on
    /// and bounded by an LRU size cap.
    let originalsCache = ThumbnailCache(
        namespace: "originals",
        derivative: "original",
        configuration: MacMediaCachePolicy.thumbnailByteCacheConfiguration()
    )

    /// Whole-library GPS index for the Map view. GPS is sensitive PII, so it is encrypted at rest
    /// (`PhotoLocationStore`, same per-account key as the media caches) and decrypted only into the in-memory
    /// `PhotoLocationIndex`. Filled by a low-priority background crawl behind the thumbnail crawl; purged on
    /// sign-out. The Map UI binds to `locationIndex`.
    var locationStore: PhotoLocationStore { locationCrawl.store }
    var locationIndex: PhotoLocationIndex { locationCrawl.index }
    /// Loads the area the map opens at into MapKit's cache, so the map draws at once.
    @ObservationIgnored private let mapPrewarmer = PhotoMapPrewarmer()
    /// The GPS crawl session shared with iOS. The account configuration and the prewarmer stay here.
    @ObservationIgnored private let locationCrawl = LocationCrawlSession(
        platform: .init(headStart: .seconds(8), requiresStoreSession: false))
    private var locationConfigurationGeneration: UInt64 = 0
    private var locationConfigurationTask: Task<Void, Never>?
    private var originalsCapEnforcementTask: Task<Void, Never>?
    /// Admission for account-bound cap passes. Teardown closes it before its first suspension, so a Settings
    /// change during sign-out cannot start a pass that outlives the purge; the persisted cap applies at the
    /// next `configure(session:)`.
    private var originalsCapGate = JoinedShutdownGate()
    private var configuredAccountUID: String?

    /// Persisted switch for retaining viewed originals in the encrypted cache up to the configured cap.
    /// Thumbnail crawling is independent of this setting.
    private(set) var offlineEnabled: Bool

    /// Current originals-cache byte budget, or `nil` when the user chose "unbounded".
    var originalsCapBytes: Int64? {
        let d = UserDefaults.standard
        if d.bool(forKey: AppSettingsKey.offlineOriginalsCapUnlimited) { return nil }
        let gb =
            d.object(forKey: AppSettingsKey.offlineOriginalsCapGB) as? Double
            ?? AppSettingsDefault.offlineOriginalsCapGB
        return Int64(max(0, gb) * 1_073_741_824)  // Convert GiB to bytes.
    }

    /// Latest computed status for the Developer/Cache surface (refreshed on demand).
    private(set) var status = OfflineCacheStatus()

    /// True only while thumbnails for newly discovered authoritative assets remain unresolved.
    private(set) var isLibraryActivityActive = false
    private let thumbnailUpdateCoordinator = LibraryThumbnailUpdateCoordinator()

    private var feed: ThumbnailFeed?
    private var statsProvider: (any LibraryStatsProvider)?
    private let statsCoordinator = OfflineLibraryStatsCoordinator()
    private var statsSession: OfflineLibraryStatsCoordinator.Session?
    private var statsTeardownSession: OfflineLibraryStatsCoordinator.Session?
    private var accountTeardownInProgress = false
    /// Live count of photos currently loaded into the timeline (pushed by `MainView`).
    var liveAssetCount = 0 {
        didSet {
            if liveAssetCount != oldValue { markStatusDirty() }
        }
    }

    private struct StatusReadContext: Sendable {
        let feed: ThumbnailFeed?
        let statsProvider: (any LibraryStatsProvider)?
        let cache: ThumbnailCache
        let previewCache: ThumbnailCache
        let originalsCache: ThumbnailCache
        let offlineEnabled: Bool
        let liveAssetCount: Int
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            AppSettingsKey.offlineLibraryEnabled: AppSettingsDefault.offlineLibraryEnabled,
            AppSettingsKey.offlineOriginalsCapUnlimited: AppSettingsDefault.offlineOriginalsCapUnlimited,
            AppSettingsKey.offlineOriginalsCapGB: AppSettingsDefault.offlineOriginalsCapGB,
        ])
        offlineEnabled = defaults.bool(forKey: AppSettingsKey.offlineLibraryEnabled)
    }

    /// Called by `MainView` after backend and feed creation. Thumbnail crawling is grid infrastructure
    /// and remains enabled independently of the offline-originals setting.
    func attach(feed: ThumbnailFeed, stats: any LibraryStatsProvider) {
        self.feed = feed
        self.statsProvider = stats
        markStatusDirty()
        Task {
            await feed.setPrefetchEnabled(OfflineLibraryPolicy.shouldCrawlThumbnails(offlineEnabled: offlineEnabled))
        }
    }

    /// Clears account-derived values from observable Settings state before asynchronous teardown begins.
    func prepareForAccountTeardown() {
        accountTeardownInProgress = true
        if let statsSession {
            statsCoordinator.invalidate(statsSession)
            statsTeardownSession = statsSession
            self.statsSession = nil
        }
        liveAssetCount = 0
        isLibraryActivityActive = false
        status = OfflineCacheStatus()
    }

    func reconcileNewAssetThumbnails(currentUIDs: [PhotoUID], addedUIDs: [PhotoUID]) {
        guard let feed else {
            thumbnailUpdateCoordinator.cancel()
            return
        }
        thumbnailUpdateCoordinator.reconcile(
            currentUIDs: currentUIDs,
            addedUIDs: addedUIDs,
            onStateChange: { [weak self] state in
                self?.isLibraryActivityActive = state.isActive
            },
            resolver: { uids, enqueueMissing in
                await feed.libraryUpdateResolution(for: uids, enqueueMissing: enqueueMissing)
            }
        )
    }

    /// Installs the per-account encryption key for the thumbnail + preview caches. Called at sign-in,
    /// before the grid starts crawling. The key is derived from the
    /// already-unlocked session secret, so startup needs only the session Keychain item rather than a second
    /// Keychain prompt for a separate cache key item.
    func configure(session: ProtonSession) {
        let context = LocalMediaCacheContext(accountUID: session.uid, keyPassword: session.keyPassword)
        let previousAccountUID = configuredAccountUID
        accountTeardownInProgress = false
        status = OfflineCacheStatus()
        // Configuration remains the original security transition even for the same account:
        // refresh credentials and invalidate old cache writer/retention generations.
        // Statistics read immutable cache directories and revalidate this session before
        // publication; account teardown still joins readers before closing provider stores.
        statsSession = statsCoordinator.beginSession()
        context.configure(cache, previewCache, originalsCache)
        let previousCrawlStarted = locationCrawl.isStarted
        let accountChanged = previousAccountUID != nil && previousAccountUID != context.accountUID
        locationConfigurationGeneration &+= 1
        let configurationGeneration = locationConfigurationGeneration
        configuredAccountUID = context.accountUID
        let previousConfiguration = locationConfigurationTask
        previousConfiguration?.cancel()
        let previousStarter = locationCrawl.invalidate()
        if accountChanged {
            locationIndex.replaceAll([])
            locationIndex.updateScanProgress(PhotoLocationScanProgress())
        }
        let accountUID = context.accountUID
        let key = context.encryptionKey
        locationConfigurationTask = Task { @MainActor [weak self, previousConfiguration, previousStarter] in
            await previousConfiguration?.value
            await previousStarter?.value
            guard let self,
                !Task.isCancelled,
                self.locationConfigurationGeneration == configurationGeneration,
                self.configuredAccountUID == accountUID
            else { return }
            if previousCrawlStarted {
                await self.locationCrawl.crawl.cancel()
            }
            guard !Task.isCancelled,
                self.locationConfigurationGeneration == configurationGeneration,
                self.configuredAccountUID == accountUID
            else { return }
            let sessionLease = self.locationStore.configure(accountUID: accountUID, key: key)
            let store = self.locationStore
            let snapshot = await Task.detached(priority: .utility) {
                store.loadSnapshot()
            }.value
            guard !Task.isCancelled,
                self.locationConfigurationGeneration == configurationGeneration,
                self.configuredAccountUID == accountUID,
                self.locationStore.isCurrentSessionLease(sessionLease)
            else { return }
            self.locationIndex.replaceAll(snapshot)
            // Map tiles come from Apple, so this runs only where the Map was opened before.
            self.mapPrewarmer.prewarm(coordinates: self.locationIndex.coordinates)
            self.locationConfigurationTask = nil
        }
        if originalsCapGate.isClosed { originalsCapGate = JoinedShutdownGate() }
        if let cap = originalsCapBytes {
            enforceOriginalsCap(cap)
        }
    }

    /// Chains cap passes so a later cap replaces, rather than races, an earlier one. Each pass is admitted
    /// through `originalsCapGate`; a pass that reaches the gate after teardown closed it does nothing.
    @discardableResult
    private func enforceOriginalsCap(_ cap: Int64) -> Task<Void, Never> {
        let oc = originalsCache
        let gate = originalsCapGate
        let previous = originalsCapEnforcementTask
        let task = Task.detached(priority: .utility) {
            await previous?.value
            try? await gate.withAdmission { oc.enforceByteCap(cap) }
        }
        originalsCapEnforcementTask = task
        return task
    }

    /// Stops account-bound location and activity work before any facade or cache owner is closed.
    /// Kept separate from cache deletion so the shared account teardown stages stay explicit.
    func stopForAccountTeardown() async {
        originalsCapGate.closeAdmission()
        let retiringStatsSession = statsTeardownSession
        let activeLocationConfiguration = locationConfigurationTask
        let activeFeed = feed
        locationConfigurationGeneration &+= 1
        let activeLocationCrawlStarter = locationCrawl.retire()
        activeLocationConfiguration?.cancel()
        locationConfigurationTask = nil
        locationIndex.replaceAll([])
        locationIndex.updateScanProgress(PhotoLocationScanProgress())
        let activeThumbnailUpdateTask = thumbnailUpdateCoordinator.cancel()
        feed = nil
        statsProvider = nil
        liveAssetCount = 0
        configuredAccountUID = nil
        await activeLocationConfiguration?.value
        await activeLocationCrawlStarter?.value
        await activeThumbnailUpdateTask?.value
        // Joins every admitted cap pass; a pass admitted after `closeAdmission()` never runs.
        await originalsCapGate.closeAdmissionAndJoin()
        originalsCapEnforcementTask = nil
        if let retiringStatsSession {
            await statsCoordinator.stopAndJoin(retiringStatsSession)
            if statsTeardownSession == retiringStatsSession { statsTeardownSession = nil }
        }
        await activeFeed?.stopPrefetch()
        await locationCrawl.crawl.cancel()
        // A non-cooperative metadata probe can return after the eager UI clear above but before the
        // joined Core cancellation completes. Clear once more at the retirement barrier.
        locationIndex.replaceAll([])
        locationIndex.updateScanProgress(PhotoLocationScanProgress())
    }

    /// Erases encrypted thumbnail/preview blobs, their account keys, location data, and streamed
    /// video blocks after account-owned workers and stores have stopped.
    func purgeCachesForAccountTeardown() async {
        let cache = cache
        let previewCache = previewCache
        let originalsCache = originalsCache
        let locationStore = locationStore
        await Task.detached(priority: .utility) {
            cache.clearForSignOut()
            previewCache.clearForSignOut()
            originalsCache.clearForSignOut()
            VideoByteRangeCache.shared.clearAll()
            locationStore.clear()
        }.value
    }

    /// Starts one resumable, throttled GPS crawl for the Map view. It yields to visible thumbnail work and
    /// persists the encrypted index periodically. Repeated calls are safe.
    func startLocationCrawl(items: [PhotoItem]?, metadata: any PhotoMetadataProvider) {
        locationCrawl.startWholeLibrary(items: items) { makeLocationCrawlStart(metadata: metadata) }
    }

    /// The account configuration that location work started for. Capture it before the first suspension of a
    /// trash, restore or publication; every later account configuration or teardown rejects it.
    func captureLocationOwner() -> LocationCrawlSession.OwnerLease { locationCrawl.captureOwnerLease() }

    func publishLocationInventory(
        items: [PhotoItem]?,
        owner: LocationCrawlSession.OwnerLease,
        metadata: any PhotoMetadataProvider,
        isCurrent: @MainActor () -> Bool
    ) async {
        await locationCrawl.publishWholeLibrary(
            items: items, owner: owner, isCurrent: isCurrent,
            makeStart: { makeLocationCrawlStart(metadata: metadata) }
        )
    }

    private func makeLocationCrawlStart(metadata: any PhotoMetadataProvider) -> LocationCrawlSession.Start {
        let accountUID = configuredAccountUID ?? ""
        let configurationGeneration = locationConfigurationGeneration
        let feed = self.feed
        return LocationCrawlSession.Start(
            accountUID: accountUID,
            location: LocationCrawl.metadataProbe(metadata),
            visibleDemand: { await feed?.hasVisibleThumbnailPressure() ?? false },
            log: { DebugLog.log($0) },
            isCurrent: { [weak self] in
                self?.configuredAccountUID == accountUID
                    && self?.locationConfigurationGeneration == configurationGeneration
            },
            awaiting: locationConfigurationTask
        )
    }

    func pauseMapAndPlaces() {
        mapPrewarmer.cancel()
        locationCrawl.pause()
    }

    func resumeMapAndPlaces(items: [PhotoItem]?, metadata: any PhotoMetadataProvider) {
        guard MapAndPlacesPolicy.isEnabled() else { return }
        mapPrewarmer.prewarm(coordinates: locationIndex.coordinates)
        startLocationCrawl(items: items, metadata: metadata)
    }

    func restartLocationCrawl(items: [PhotoItem]?, metadata: any PhotoMetadataProvider) {
        locationCrawl.startWholeLibrary(items: items, restarting: true) {
            makeLocationCrawlStart(metadata: metadata)
        }
    }

    /// Keeps map pins and the encrypted snapshot aligned with a successful library mutation. A restore only
    /// restarts GPS probing when the user already activated Map work this session.
    func reconcileLocations(
        items: [PhotoItem]?,
        owner: LocationCrawlSession.OwnerLease,
        metadata: any PhotoMetadataProvider,
        recrawlRestoredItems: Bool,
        isCurrent: @MainActor () -> Bool = { true }
    ) async {
        await locationCrawl.reconcileWholeLibrary(
            items: items,
            recrawlRestoredItems: recrawlRestoredItems,
            owner: owner,
            isCurrent: isCurrent,
            makeStart: { makeLocationCrawlStart(metadata: metadata) }
        )
    }

    /// Persists the Offline Photo Library setting. Enabled mode stores viewed originals in the encrypted
    /// `originals` cache; disabled mode stops retention and lets Settings purge existing originals.
    /// Thumbnail crawling remains enabled by `OfflineLibraryPolicy`.
    func setOfflineEnabled(_ enabled: Bool) {
        guard enabled != offlineEnabled else { return }
        offlineEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AppSettingsKey.offlineLibraryEnabled)
        markStatusDirty()
    }

    /// Persists the originals-cache cap and enforces it immediately - lowering it (or switching from unbounded to
    /// bounded) purges the least-recently-used originals down to the new budget right away.
    func setOriginalsCap(unlimited: Bool, gigabytes: Double) {
        let d = UserDefaults.standard
        d.set(unlimited, forKey: AppSettingsKey.offlineOriginalsCapUnlimited)
        d.set(gigabytes, forKey: AppSettingsKey.offlineOriginalsCapGB)
        guard let cap = originalsCapBytes else { return }  // An unbounded cache needs no cap enforcement.
        let task = enforceOriginalsCap(cap)
        Task {
            await task.value  // file I/O off the main actor
            markStatusDirty()
            await refreshStatus()
        }
    }

    /// The three media caches whose size Settings shows.
    var diskCaches: ThumbnailCacheGroup { ThumbnailCacheGroup([cache, previewCache, originalsCache]) }

    /// Clears the full-resolution originals cache when retention is disabled. Thumbnail and preview caches
    /// and the account key remain available to the grid.
    func purgeOriginalsCache() async {
        await originalsCache.clear()
        markStatusDirty()
        await refreshStatus()
    }

    /// Erases all account media caches and streamed video blocks while retaining the account key. The grid
    /// repopulates them on its next crawl. Callers invoke this only from the explicit cache-delete action.
    func deleteOfflineCache() async {
        if let feed {
            await feed.clearCacheAndRestartPrefetch()
        } else {
            await cache.clear()
        }
        await previewCache.clear()
        await originalsCache.clear()
        await VideoByteRangeCache.shared.clearAllAsync()  // also drop streamed video blocks
        markStatusDirty()
        await refreshStatus()
    }

    /// Recomputes `status` from the cache actors, the feed, and the diagnostics counters.
    @discardableResult
    func refreshStatus() async -> OfflineCacheStatus {
        guard !accountTeardownInProgress,
            let session = statsSession,
            var requiredDemand = statsCoordinator.requestRefresh(in: session)
        else { return status }

        while true {
            let measurement = await statsCoordinator.refresh(
                in: session,
                satisfying: requiredDemand
            ) { [weak self] in
                guard let initial = await self?.statusReadContext(for: session) else { return nil }
                let prefetch = await initial.feed?.prefetchStatus()
                let metadataRows = await initial.statsProvider?.metadataRowCount() ?? 0
                // Revalidate the account owner after the asynchronous providers and before synchronous disk walks.
                guard let current = await self?.statusReadContext(for: session) else { return nil }

                let thumbnailSizeBytes = current.cache.trackedDiskSizeBytes()
                let previewSizeBytes = current.previewCache.trackedDiskSizeBytes()
                let originalsSizeBytes = current.originalsCache.trackedDiskSizeBytes()
                let totalAssets = max(current.liveAssetCount, metadataRows)
                var snapshot = OfflineCacheStatus()
                snapshot.offlineEnabled = current.offlineEnabled
                snapshot.totalAssets = totalAssets
                snapshot.metadataRows = metadataRows
                // Source-aware feeds report coverage for the primary projection only. Physical cache bytes still
                // include authorized analysis-only derivatives and remain reflected in `cacheSizeBytes` below.
                snapshot.thumbnailsOnDisk = prefetch?.diskFileCount ?? current.cache.diskFileCount()
                snapshot.thumbnailsMissing = max(0, totalAssets - snapshot.thumbnailsOnDisk)
                snapshot.ramDecodedEstimate = prefetch?.ramDecodedCount ?? 0
                snapshot.prefetchQueueDepth = prefetch?.currentQueueLength ?? 0
                snapshot.activePrefetchJobs = prefetch?.activeJobs ?? 0
                // Thumbnails always crawl, so the offline toggle never reports "disabled" here.
                snapshot.prefetchPausedReason = prefetch?.pausedReason ?? "none"
                snapshot.failedThumbnailCount = prefetch?.failed ?? 0
                snapshot.cacheSizeBytes = thumbnailSizeBytes
                snapshot.previewCacheSizeBytes = previewSizeBytes
                snapshot.originalsCacheSizeBytes = originalsSizeBytes
                snapshot.lastError = prefetch?.lastErrors.last
                return snapshot
            }
            guard let measurement,
                statsSession == session,
                !accountTeardownInProgress
            else { return status }
            if statsCoordinator.isCurrent(measurement.demand, in: session) {
                status = measurement.status
                return measurement.status
            }
            guard let currentDemand = statsCoordinator.currentDemand(in: session) else { return status }
            requiredDemand = currentDemand
        }
    }

    private func markStatusDirty() {
        guard let statsSession else { return }
        statsCoordinator.markDirty(in: statsSession)
    }

    private func statusReadContext(
        for session: OfflineLibraryStatsCoordinator.Session
    ) -> StatusReadContext? {
        guard statsSession == session, !accountTeardownInProgress else { return nil }
        return StatusReadContext(
            feed: feed,
            statsProvider: statsProvider,
            cache: cache,
            previewCache: previewCache,
            originalsCache: originalsCache,
            offlineEnabled: offlineEnabled,
            liveAssetCount: liveAssetCount
        )
    }
}
