import AVFoundation
import AlbumCore
import AppKit
import Foundation
import MediaByteCache
import MediaCache
import MediaFeedCore
import PhotoViewerCore
import PhotosCore
import VisionKit

/// Drives the full-screen viewer with progressive quality: grid thumbnail, bounded preview, then original.
///
/// Video playback uses an explicit `VideoViewerState` machine instead of inferring "loading" from a tangle
/// of optionals. Streaming is the only video path: falling back to a decrypted local temp file is forbidden
/// by the local E2EE rule. One `AVPlayer` is retained for the streaming path, so the view never re-creates
/// the player on a redraw.
@MainActor
@Observable
public final class PhotoViewerModel {
    public private(set) var items: [PhotoItem]
    public private(set) var index: Int

    /// Best image available so far for the current item.
    public private(set) var image: NSImage?
    /// True once a bounded original representation is shown - drives the crossfade reveal from the interim image.
    public private(set) var isSharp = false
    /// On-device Live Text of the displayed sharp still. `nil` while the photo loads or has no text.
    public private(set) var liveTextAnalysis: ImageAnalysis?
    /// Highlights the recognized text. Every photo starts unhighlighted.
    public var liveTextHighlighted = false
    public var hasLiveText: Bool { liveTextAnalysis != nil }
    /// Owns the AVPlayer + the video state machine (streaming, watchdog, stall/buffer handling). The
    /// model decides *which* source to play; the controller decides *how it's going*.
    public let video: VideoPlaybackController
    /// The single AVPlayer used for video (streaming or downloaded). `nil` for images.
    public var player: AVPlayer? { video.player }
    /// Explicit video lifecycle - the view shows progress / error from this.
    public var videoState: VideoViewerState { video.state }
    /// Download progress (0…1) of the full original - used to show a progress indicator for big
    /// downloads instead of an indefinite spinner.
    public private(set) var originalProgress: Double = 0
    public private(set) var isLoadingOriginal = false
    public private(set) var originalLoadFailed = false

    // MARK: Live Photo motion clip
    /// The paired Live Photo motion clip's shared controller (single AVPlayer + play/stop state). The same
    /// controller drives the iOS viewer, so motion behavior - E2EE preload, instant playback, crossfade - is not
    /// forked per platform. See `LivePhotoMotionController`.
    public let motion = LivePhotoMotionController()
    /// The motion clip's player once fully preloaded, else nil (still loading / not a Live Photo / disabled).
    public var motionPlayer: AVPlayer? { motion.player }
    /// True while the motion clip is playing - the view crossfades the motion layer in/out on this.
    public var isMotionPlaying: Bool { motion.isPlaying }
    public var livePhotoReadiness: LivePhotoCompositeReadiness {
        LivePhotoCompositeReadiness.resolve(
            requiresMotion: LivePhotoMotionPolicy.shouldPrepare(item: current, hasStreamer: streamer != nil),
            isFullResolutionStillReady: isSharp,
            didFullResolutionStillFail: originalLoadFailed,
            motionState: motion.loadState,
            isMotionRequested: motion.isPlayRequested
        )
    }

    /// Whether the info panel is open, and the metadata for the current item (loaded lazily).
    public var showInfo = false
    public private(set) var metadataLoadState: PhotoMetadataLoadState = .idle
    public var metadata: PhotoMetadata? { metadataLoadState.metadata }
    public private(set) var albumTitles: [String] = []
    public private(set) var isLoadingAlbumMemberships = false
    public private(set) var albumMembershipsLoadFailed = false
    public var canLoadAlbumMemberships: Bool { albumMembershipProvider != nil }

    /// Known GPS photos keep their two-line geometry while nearby metadata resolves. Photos without a proven
    /// location show their capture date immediately; normal navigation still promotes prefetched POI text.
    public private(set) var titleMetadataState: ViewerTitleMetadataState = .resolving
    public var placeName: String? { titleMetadataState.resolution?.placeName }
    public var isPlaceNameResolving: Bool {
        titleMetadataState.shouldReservePlaceNameLine(
            hasKnownLocation: knownLocationUIDs.contains(current.uid)
        )
    }

    private let feed: ThumbnailFeed
    public let allowsVisibleDuplicateThumbnails: Bool
    private let visibleThumbnail: VisibleThumbnailSession?
    private var pageIndex: ViewerPageIndex
    private let media: FullMediaProvider
    private let originalByteStreamer: (any OriginalByteStreamProvider)?
    private let streamer: VideoStreamProvider?
    private let metadataProvider: PhotoMetadataProvider?
    private let albumMembershipProvider: (any PhotoAlbumMembershipProviding)?
    private let titleMetadataCoordinator: ViewerTitleMetadataCoordinator
    private let knownLocationUIDs: Set<PhotoUID>
    private let burstProvider: BurstGroupProvider?
    private let previewCache: ThumbnailCache?
    /// Encrypted disk cache for full-resolution originals (offline library). Viewer page appearance does not read
    /// this whole-file representation; explicit unbounded fallback loads may write it when enabled.
    private let originalsCache: ThumbnailCache?
    /// Whether to persist newly-downloaded originals through the legacy whole-file fallback.
    private let cacheOriginals: Bool
    private let originalsCapBytes: Int64?
    /// Stable leases for every cache owned by this viewer. They fail closed when account configuration changes.
    private let previewSessionLease: CacheWriterGeneration.SessionToken?
    private let originalsSessionLease: CacheWriterGeneration.SessionToken?
    private let sessionCache: ThumbnailCache?
    private let sessionLease: CacheWriterGeneration.SessionToken?
    private var loadTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var albumMembershipTask: Task<Void, Never>?
    private var placeTask: Task<Void, Never>?
    private var burstTask: Task<Void, Never>?
    private var loadedSharpPixelSize = 0
    private var requestedSharpPixelSize = 0
    private var originalLoadGeneration: UInt64 = 0
    private var burstSelection = BurstSelectionModel()
    private let editedOriginalProvider: (any EditedPhotoOriginalProviding)?
    private let editedOriginalLookup = EditedPhotoOriginalLookup()
    /// The originals of edited photos that this viewer found, and whether the page shows one.
    public private(set) var editedOriginal = EditedPhotoOriginalState()

    public var burstItems: [PhotoItem] { burstSelection.items }
    public var burstIndex: Int? { burstSelection.selectedIndex }
    public var isLoadingBurst: Bool { burstSelection.isLoading }

    public init(
        items: [PhotoItem], index: Int, feed: ThumbnailFeed, media: FullMediaProvider,
        streamer: VideoStreamProvider? = nil, metadataProvider: PhotoMetadataProvider? = nil,
        albumMembershipProvider: (any PhotoAlbumMembershipProviding)? = nil,
        placeNameResolver: (any PlaceNameResolving)? = nil,
        knownLocationUIDs: Set<PhotoUID> = [],
        burstProvider: BurstGroupProvider? = nil,
        previewCache: ThumbnailCache? = nil, originalsCache: ThumbnailCache? = nil,
        cacheOriginals: Bool = false, originalsCapBytes: Int64? = nil,
        allowsVisibleDuplicateThumbnails: Bool = false,
        editedOriginalProvider: (any EditedPhotoOriginalProviding)? = nil
    ) {
        self.items = items
        self.index = index
        self.pageIndex = ViewerPageIndex(orderedUIDs: items.map(\.uid))
        self.feed = feed
        self.allowsVisibleDuplicateThumbnails = allowsVisibleDuplicateThumbnails
        self.visibleThumbnail = allowsVisibleDuplicateThumbnails ? VisibleThumbnailSession(feed: feed.feedCore) : nil
        self.media = media
        self.originalByteStreamer = media as? any OriginalByteStreamProvider
        self.streamer = streamer
        self.metadataProvider = metadataProvider
        self.albumMembershipProvider = albumMembershipProvider
        self.titleMetadataCoordinator = ViewerTitleMetadataCoordinator(
            metadataProvider: metadataProvider,
            placeNameResolver: placeNameResolver
        )
        self.knownLocationUIDs = knownLocationUIDs
        self.burstProvider = burstProvider
        self.editedOriginalProvider = editedOriginalProvider
        self.previewCache = previewCache
        self.originalsCache = originalsCache
        self.cacheOriginals = cacheOriginals
        self.originalsCapBytes = originalsCapBytes
        self.previewSessionLease = previewCache?.captureSessionLease()
        self.originalsSessionLease = originalsCache?.captureSessionLease()
        self.sessionCache = originalsCache ?? previewCache
        self.sessionLease = (originalsCache ?? previewCache)?.captureSessionLease()
        Self.prepareFullImageCache(cache: self.sessionCache, lease: self.sessionLease)
        self.video = VideoPlaybackController { event in
            PhotoDiagnostics.shared.emit(event.name, event.fields, throttleSeconds: event.throttleSeconds)
        }
    }

    private func sessionIsCurrent() -> Bool {
        let previewCurrent =
            previewCache.map { cache in
                guard let lease = previewSessionLease else { return false }
                return cache.isCurrentSessionLease(lease)
            } ?? true
        let originalsCurrent =
            originalsCache.map { cache in
                guard let lease = originalsSessionLease else { return false }
                return cache.isCurrentSessionLease(lease)
            } ?? true
        let sessionCurrent =
            sessionCache.map { cache in
                guard let lease = sessionLease else { return false }
                return cache.isCurrentSessionLease(lease)
            } ?? true
        return previewCurrent && originalsCurrent && sessionCurrent
    }

    public func toggleInfo() {
        showInfo.toggle()
        if showInfo {
            loadMetadata()
            loadAlbumMemberships()
        }
    }

    public func retryMetadata() {
        guard showInfo else { return }
        titleMetadataCoordinator.invalidate(current.uid)
        resolvePlaceName(for: current)
        loadMetadata()
        loadAlbumMemberships()
    }

    public func refreshPlaceNames() {
        placeTask?.cancel()
        titleMetadataCoordinator.cancelAll()
        resolvePlaceName(for: current)
    }

    private func loadAlbumMemberships() {
        albumMembershipTask?.cancel()
        albumTitles = []
        albumMembershipsLoadFailed = false
        guard let albumMembershipProvider else {
            isLoadingAlbumMemberships = false
            return
        }
        let item = current
        isLoadingAlbumMemberships = true
        albumMembershipTask = Task { [weak self, albumMembershipProvider] in
            do {
                let titles = try await albumMembershipProvider.albumMembershipTitles(for: item.uid)
                guard !Task.isCancelled, let self, self.isDisplaying(item) else { return }
                self.albumTitles = titles
                self.isLoadingAlbumMemberships = false
            } catch {
                guard !Task.isCancelled, let self, self.isDisplaying(item) else { return }
                self.isLoadingAlbumMemberships = false
                self.albumMembershipsLoadFailed = true
            }
        }
    }

    /// Loads metadata for the current item (only while the panel is open). Cancels on navigation.
    private func loadMetadata() {
        metadataTask?.cancel()
        albumMembershipTask?.cancel()
        let item = current
        if let resolution = titleMetadataCoordinator.state(for: item.uid).resolution {
            metadataLoadState = resolution.metadataLoadState
            return
        }
        metadataLoadState = .loading
        metadataTask = Task { [weak self, titleMetadataCoordinator] in
            let resolution = await titleMetadataCoordinator.resolve(item)
            guard !Task.isCancelled, let self, self.isDisplaying(item) else { return }
            self.metadataLoadState = resolution.metadataLoadState
        }
    }

    /// Resolves the current headline and prefetches a bounded neighbor window. The coordinator owns the one
    /// cross-platform metadata/geocode cache, so platform views do not race independent POI requests.
    private func resolvePlaceName(for item: PhotoItem) {
        placeTask?.cancel()
        titleMetadataCoordinator.prepare(items: items, around: index)
        titleMetadataState = titleMetadataCoordinator.state(for: item.uid)
        placeTask = Task { [weak self, titleMetadataCoordinator] in
            let resolution = await titleMetadataCoordinator.resolve(item)
            guard !Task.isCancelled, let self, self.isDisplaying(item) else { return }
            self.titleMetadataState = .resolved(resolution)
            if self.showInfo, let metadata = resolution.metadata {
                self.metadataLoadState = .loaded(metadata)
            }
        }
    }

    public var baseCurrent: PhotoItem { items[index] }
    public var current: PhotoItem {
        burstSelection.current(fallback: editedOriginal.displayed(baseCurrent))
    }
    /// The page is an edited photo whose original this viewer found.
    public var canShowOriginal: Bool { editedOriginal.canShowOriginal(of: baseCurrent.uid) }
    public var isShowingOriginal: Bool { editedOriginal.isShowingOriginal(of: baseCurrent.uid) }

    /// Switches the page between the edited version and its original.
    public func toggleOriginal() {
        guard canShowOriginal else { return }
        editedOriginal.toggle(baseCurrent.uid)
        loadDisplayedItem(current)
    }
    public var canGoNext: Bool { index < items.count - 1 }
    public var canGoPrevious: Bool { index > 0 }
    public var canNavigateNext: Bool {
        burstSelection.canMoveNext || canGoNext
    }
    public var canNavigatePrevious: Bool {
        burstSelection.canMovePrevious || canGoPrevious
    }
    public var thumbnailFeed: ThumbnailFeed { feed }
    public var hasBurstFilmstrip: Bool { burstSelection.hasFilmstrip }
    public var exportItemsForDownload: [PhotoItem] {
        burstSelection.exportItems(current: current)
    }
    public var canDownloadCurrentSelection: Bool {
        !isLoadingBurst && !exportItemsForDownload.isEmpty
    }
    public var gridReturnCandidates: [PhotoItem] {
        burstSelection.gridReturnCandidates(current: current, base: baseCurrent)
    }
    private func isDisplaying(_ item: PhotoItem) -> Bool { current.uid == item.uid }
    private func isBaseCurrent(_ item: PhotoItem) -> Bool { baseCurrent.uid == item.uid }

    public func start() { loadCurrent() }

    /// Called when the viewer closes: cancels any in-flight load and tears the player down so closing
    /// stops playback/audio immediately and cancels unnecessary streaming/download work.
    public func stop() {
        visibleThumbnail?.end()
        originalLoadGeneration &+= 1
        loadTask?.cancel()
        burstTask?.cancel()
        metadataTask?.cancel()
        albumMembershipTask?.cancel()
        placeTask?.cancel()
        editedOriginalLookup.cancel()
        titleMetadataCoordinator.cancelAll()
        isLoadingOriginal = false
        video.teardown()
        motion.teardown()
    }

    // MARK: - Live Photo motion playback

    /// Plays the paired motion clip with sound. The Live badge hover and force-click actions call this method.
    /// the E2EE-safe preload/playback logic lives in the shared `LivePhotoMotionController`.
    public func playMotion() {
        let item = current
        motion.play(for: item, streamer: streamer) { [weak self] in self?.isDisplaying(item) ?? false }
    }

    /// Stops the motion clip and crossfades back to the still (hover-out, or auto at end-of-clip).
    public func stopMotion() { motion.stop() }

    public func next() {
        guard canGoNext else { return }
        index += 1
        loadCurrent()
    }

    public func previous() {
        guard canGoPrevious else { return }
        index -= 1
        loadCurrent()
    }

    /// Selects a library page by its full account-scoped identity. Native filmstrips can therefore keep
    /// selection stable without duplicating route-order lookup or falling back to a raw array offset.
    @discardableResult
    public func selectPage(uid: PhotoUID) -> Bool {
        guard let resolved = pageIndex.index(of: uid) else { return false }
        guard resolved != index else { return true }
        index = resolved
        loadCurrent()
        return true
    }

    /// Swaps photos that the backup replaced in `timeline` for their replacement. The open page reloads only when
    /// its own photo was replaced; see `ViewerReplacementFollow`.
    public func followReplacements(_ replacements: [PhotoUID: PhotoUID], in timeline: TimelineSnapshot) {
        guard
            let followed = ViewerReplacementFollow.follow(
                items, pages: pageIndex, current: index, replacements: replacements, timeline: timeline)
        else { return }
        let replacesCurrent = items.indices.contains(index) && followed.items[followed.current].uid != items[index].uid
        items = followed.items
        pageIndex = followed.pages
        index = followed.current
        if replacesCurrent { loadCurrent() }
    }

    /// Contextual keyboard/button navigation. A visible burst/series filmstrip is a nested selection, so
    /// left/right first move through series members; at the series edges they fall through to the adjacent
    /// library item, matching keyboard accessibility expectations for an active sub-selection.
    public func nextInContext() {
        if let selected = burstSelection.selectNext() {
            loadDisplayedItem(selected)
            return
        }
        next()
    }

    public func previousInContext() {
        if let selected = burstSelection.selectPrevious() {
            loadDisplayedItem(selected)
            return
        }
        previous()
    }

    public func selectBurstIndex(_ newIndex: Int) {
        guard let selected = burstSelection.selectIndex(newIndex) else { return }
        loadDisplayedItem(selected)
    }

    /// In-memory cache of already-loaded full-resolution images (shared across viewer instances) so
    /// reopening / re-navigating to a photo is instant and never re-shows the spinner.
    private static let fullImageCacheCountLimit = 8
    private static let fullImageCacheByteLimit = 512 * 1024 * 1024
    private final class CachedSharpImage: NSObject {
        let image: NSImage
        let pixelSize: Int

        init(image: NSImage, pixelSize: Int) {
            self.image = image
            self.pixelSize = pixelSize
        }
    }
    private static let fullImageCache: NSCache<NSString, CachedSharpImage> = {
        let c = NSCache<NSString, CachedSharpImage>()
        c.countLimit = fullImageCacheCountLimit
        c.totalCostLimit = fullImageCacheByteLimit
        return c
    }()
    private struct FullImageCacheScope: Equatable {
        let cacheID: ObjectIdentifier
        let lease: CacheWriterGeneration.SessionToken
    }
    private static var fullImageCacheScope: FullImageCacheScope?

    private static func prepareFullImageCache(
        cache: ThumbnailCache?,
        lease: CacheWriterGeneration.SessionToken?
    ) {
        guard let cache, let lease else {
            fullImageCache.removeAllObjects()
            fullImageCacheScope = nil
            return
        }
        let scope = FullImageCacheScope(cacheID: ObjectIdentifier(cache), lease: lease)
        if fullImageCacheScope != scope {
            fullImageCache.removeAllObjects()
            fullImageCacheScope = scope
        }
    }
    private static func cacheKey(_ uid: PhotoUID) -> NSString { "\(uid.volumeID)~\(uid.nodeID)" as NSString }

    /// A pending photo can change in Apple Photos before it uploads, so it always reloads from the device.
    private static func cacheFullImage(_ image: NSImage, pixelSize: Int, for uid: PhotoUID) {
        guard !uid.isLocalPending else { return }
        fullImageCache.setObject(
            CachedSharpImage(image: image, pixelSize: pixelSize),
            forKey: cacheKey(uid),
            cost: decodedImageCost(image)
        )
    }

    /// Governor-driven memory-pressure response for the shared full-resolution viewer cache - the
    /// single most jetsam-prone RAM consumer. `scale` lowers the cost limit; `purge` drops every held
    /// decode now (a revisit re-decodes from disk/network - never a crash). Static + thread-safe
    /// NSCache, callable from the governor without touching a viewer instance.
    public static func applyMemoryPressure(scale: Double, purge: Bool) {
        let clamped = min(1, max(0, scale))
        fullImageCache.totalCostLimit = max(1, Int(Double(fullImageCacheByteLimit) * clamped))
        if purge { fullImageCache.removeAllObjects() }
    }

    private static func decodedImageCost(_ image: NSImage) -> Int {
        let representationCost =
            image.representations.map { rep -> Int in
                if let bitmap = rep as? NSBitmapImageRep, bitmap.bytesPerRow > 0, bitmap.pixelsHigh > 0 {
                    return bitmap.bytesPerRow * bitmap.pixelsHigh
                }
                guard rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return 0 }
                return rep.pixelsWide * rep.pixelsHigh * 4
            }.max() ?? 0
        let fallbackCost = Int(max(1, image.size.width) * max(1, image.size.height) * 4)
        return max(1, representationCost, fallbackCost)
    }

    /// Wraps the Core `CGImage` decode as AppKit image. The heavy ImageIO decode still runs off the main actor.
    private nonisolated static func decodeFullImage(_ data: Data, maxPixelSize: Int? = nil) -> NSImage? {
        guard
            let cg = PhotoPerformanceSignposts.viewer.interval(
                "viewer.decode",
                {
                    ViewerFullImageDecoder.decodeCGImage(data, maxPixelSize: maxPixelSize)
                })
        else {
            return maxPixelSize == nil ? NSImage(data: data) : nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private nonisolated static func decodePreviewImage(_ data: Data) -> NSImage? {
        guard
            let cg = ViewerFullImageDecoder.decodeCGImage(
                data,
                maxPixelSize: ViewerImageLoadPolicy.maxDisplayPixelSize
            )
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private nonisolated static func decodeStreamedImage(
        _ provider: any OriginalByteStreamProvider,
        uid: PhotoUID,
        maxPixelSize: Int?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> CGImage? {
        return try await ViewerFullImageDecoder.decodeStreamedCGImage(
            from: provider,
            uid: uid,
            maxPixelSize: maxPixelSize,
            onProgress: onProgress
        )
    }

    /// Recognizes text in the displayed still once the sharp image is shown. The view restarts it whenever the
    /// displayed image changes; a result for a photo that is no longer shown is dropped.
    public func refreshLiveText() async {
        guard isSharp, player == nil, let image else {
            liveTextAnalysis = nil
            return
        }
        let uid = current.uid
        let analysis = await ViewerLiveText.analyze(image)
        guard !Task.isCancelled, current.uid == uid, self.image === image else { return }
        liveTextAnalysis = analysis
        if analysis == nil { liveTextHighlighted = false }
    }

    private func loadCurrent() {
        burstTask?.cancel()
        burstSelection.reset()
        let item = baseCurrent
        editedOriginal.pageChanged(to: item.uid)
        editedOriginalLookup.settled(on: item, provider: editedOriginalProvider) { [weak self] base, original in
            self?.editedOriginal.record(original, of: base.uid)
        }
        burstSelection.seedKnownGroup(
            for: item,
            knownItems: pageIndex.items(withUIDs: item.burstMemberUIDs, from: items)
        )
        // A reload of the same page keeps its original on screen.
        loadDisplayedItem(editedOriginal.displayed(item))
        loadBurstGroupIfNeeded(for: item)
    }

    private func loadDisplayedItem(_ item: PhotoItem) {
        visibleThumbnail?.select(item.uid)
        originalLoadGeneration &+= 1
        loadTask?.cancel()
        liveTextAnalysis = nil
        liveTextHighlighted = false
        video.reset()
        motion.teardown()
        originalProgress = 0
        isLoadingOriginal = false
        originalLoadFailed = false
        loadedSharpPixelSize = 0
        requestedSharpPixelSize = 0
        if showInfo {
            loadMetadata()
            loadAlbumMemberships()
        }  // keep the open panel in sync when navigating
        resolvePlaceName(for: item)  // top-bar POI headline (debounced; skips photos flicked past)
        guard sessionIsCurrent() else {
            image = nil
            isSharp = false
            return
        }
        motion.prepare(for: item, streamer: streamer) { [weak self] in self?.isDisplaying(item) ?? false }

        // Instant: if we already have the sharp original cached, show it - no spinner, no network.
        if let cached = Self.fullImageCache.object(forKey: Self.cacheKey(item.uid)) {
            image = cached.image
            isSharp = true
            loadedSharpPixelSize = cached.pixelSize
            requestedSharpPixelSize = cached.pixelSize
            return
        }
        // Otherwise show the thumbnail synchronously so rapid arrow navigation always shows something
        // immediately), and defer the heavy load so flicking past photos doesn't fire a network
        // storm - only the photo you actually land on loads its preview/original.
        if let visibleThumbnail {
            image = visibleThumbnail.memoryImage(for: item.uid)
        } else {
            image = feed.memoryImage(for: item.uid)
        }
        isSharp = false

        loadTask = Task {
            try? await Task.sleep(for: .milliseconds(160))  // debounce: skip work for photos flicked past
            guard !Task.isCancelled, self.isDisplaying(item), self.sessionIsCurrent() else { return }

            if self.image == nil {
                // A Duplicates copy reads only its cached thumbnail here, so the preview below never waits for it.
                let thumb: NSImage?
                if let visibleThumbnail = self.visibleThumbnail {
                    thumb = await visibleThumbnail.cachedImage(for: item.uid)
                } else {
                    thumb = await self.feed.image(for: item.uid)
                }
                if let thumb, !Task.isCancelled, self.isDisplaying(item), self.sessionIsCurrent() { self.image = thumb }
            }
            // Larger preview for a crisper interim image (disk-cached for offline browsing).
            var hasDisplayPreview = false
            if let preview = await self.loadPreviewImage(item.uid), !Task.isCancelled,
                self.isDisplaying(item), self.sessionIsCurrent()
            {
                self.image = preview
                hasDisplayPreview = true
            }
            guard !Task.isCancelled, self.isDisplaying(item), self.sessionIsCurrent() else { return }

            await self.resolveMedia(for: item, needsDisplayFallback: !hasDisplayPreview)
        }
    }

    private func loadBurstGroupIfNeeded(for item: PhotoItem) {
        guard let burstProvider, burstSelection.beginLoadingIfCandidate(item) else { return }
        burstTask = Task { [weak self, burstProvider] in
            do {
                let group = try await burstProvider.burstGroup(containing: item.uid)
                guard !Task.isCancelled, let self, self.isBaseCurrent(item) else { return }
                self.burstSelection.applyLoadedGroup(group, containing: item)
            } catch {
                guard !Task.isCancelled, let self, self.isBaseCurrent(item) else { return }
                self.burstSelection.failLoading()
            }
        }
    }

    /// Preview bytes, disk-cached: serves the offline `previews` derivative if present, else fetches
    /// and persists it. Keeps the viewer browseable offline and avoids re-downloading previews.
    private func loadPreviewImage(_ uid: PhotoUID) async -> NSImage? {
        guard sessionIsCurrent() else { return nil }
        // Photos that are not in Proton yet open from Apple Photos and stay out of the Proton caches.
        let previewCache = uid.isLocalPending ? nil : self.previewCache
        let previewGeneration = previewCache?.captureWriterGeneration()
        if let cache = previewCache {
            guard let previewGeneration else { return nil }
            let cached: NSImage? = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard cache.isCurrentWriterGeneration(previewGeneration) else { return nil }
                return cache.diskData(for: uid).flatMap { Self.decodePreviewImage($0) }
            }.value
            guard sessionIsCurrent(), cache.isCurrentWriterGeneration(previewGeneration) else { return nil }
            if let cached { return cached }
        }
        guard sessionIsCurrent() else { return nil }
        guard let data = try? await media.preview(for: uid) else { return nil }
        guard sessionIsCurrent(),
            previewGeneration.map({ previewCache?.isCurrentWriterGeneration($0) ?? false }) ?? true
        else {
            return nil
        }
        let preview = await Task.detached(priority: .userInitiated) {
            Self.decodePreviewImage(data)
        }.value
        guard sessionIsCurrent(),
            previewGeneration.map({ previewCache?.isCurrentWriterGeneration($0) ?? false }) ?? true
        else {
            return nil
        }
        if let previewCache, let previewGeneration {
            Task.detached(priority: .utility) {
                _ = previewCache.storeToDisk(data, for: uid, ifCurrent: previewGeneration)
            }
        }
        return preview
    }

    // MARK: - Media resolution (image vs video)

    /// Selects the media path after resolving the item's actual type. The SDK does not always expose a useful
    /// MIME type, so the streaming probe performs a lightweight metadata check and rejects images before key
    /// setup. Videos then use byte-range streaming while images continue through the original-data path.
    private func resolveMedia(for item: PhotoItem, needsDisplayFallback: Bool) async {
        guard sessionIsCurrent() else { return }
        let shouldLoadBoundedStill = item.isLivePhoto || needsDisplayFallback
        guard let streamer else {
            if item.isVideo {
                video.fail(.streamURLUnavailable, uid: item.uid)
            } else if shouldLoadBoundedStill {
                await loadOriginalBytes(
                    for: item,
                    expecting: .image,
                    maxPixelSize: ViewerImageLoadPolicy.maxDisplayPixelSize,
                    useOfflineOriginalCache: needsDisplayFallback
                )
            }
            return
        }
        video.setResolving()
        logViewer(item, strategy: "resolving", kind: nil)
        let preparationActivity = LibraryRuntimeState.shared.beginActivity(.videoPlayback)
        defer { preparationActivity.end() }
        do {
            let stream = try await streamer.makeStreamingAsset(for: item.uid)
            guard !Task.isCancelled, self.isDisplaying(item), self.sessionIsCurrent() else {
                stream.close()
                return
            }
            isLoadingOriginal = false
            logViewer(item, strategy: "range", kind: .video)
            video.playStreaming(asset: stream.asset, retaining: stream, uid: item.uid)
        } catch is VideoStreamError {
            // A non-video server MIME uses the image path.
            guard !Task.isCancelled, self.isDisplaying(item), self.sessionIsCurrent() else { return }
            video.reset()
            logViewer(item, strategy: "image", kind: .image)
            if shouldLoadBoundedStill {
                await loadOriginalBytes(
                    for: item,
                    expecting: .image,
                    maxPixelSize: ViewerImageLoadPolicy.maxDisplayPixelSize,
                    useOfflineOriginalCache: needsDisplayFallback
                )
            }
        } catch {
            // A real video (or unknown) whose stream setup failed stays failed rather than writing a
            // decrypted full-video temp file.
            guard !Task.isCancelled, self.isDisplaying(item), self.sessionIsCurrent() else { return }
            video.reset()
            if item.isVideo {
                video.fail(VideoPlaybackError.classify(error), uid: item.uid)
            } else if shouldLoadBoundedStill {
                await loadOriginalBytes(
                    for: item,
                    expecting: .image,
                    maxPixelSize: ViewerImageLoadPolicy.maxDisplayPixelSize,
                    useOfflineOriginalCache: needsDisplayFallback
                )
            }
        }
    }

    private enum Expecting: Equatable { case unknown, image, video }

    /// Loads an original representation on demand. A byte-stream provider feeds the incremental decoder in bounded
    /// chunks; the legacy `Data` path remains only for hosts without that capability.
    private func loadOriginalBytes(
        for item: PhotoItem,
        expecting: Expecting,
        maxPixelSize: Int? = nil,
        useOfflineOriginalCache: Bool = false
    ) async {
        guard sessionIsCurrent() else { return }
        originalLoadGeneration &+= 1
        let generation = originalLoadGeneration
        let targetPixelSize = maxPixelSize ?? .max
        requestedSharpPixelSize = max(requestedSharpPixelSize, targetPixelSize)
        isLoadingOriginal = true
        originalLoadFailed = false
        if expecting == .video { video.setDownloading(0) }
        let progressAdmission = ViewerProgressAdmission()
        defer { progressAdmission.close() }
        let ref = WeakViewerRef(self)
        // Without a writer generation, a local pending original neither reads nor fills the originals cache.
        let originalWriterGeneration = item.uid.isLocalPending ? nil : originalsCache?.captureWriterGeneration()
        do {
            let full: NSImage?
            let data: Data?
            if useOfflineOriginalCache,
                expecting != .video,
                let cached = await cachedOriginalImage(
                    for: item,
                    maxPixelSize: maxPixelSize,
                    writerGeneration: originalWriterGeneration
                )
            {
                full = cached
                data = nil
            } else if let originalByteStreamer, !(cacheOriginals && useOfflineOriginalCache) {
                let cg = try await Self.decodeStreamedImage(
                    originalByteStreamer,
                    uid: item.uid,
                    maxPixelSize: maxPixelSize,
                    onProgress: { p in
                        guard let sample = progressAdmission.admit(p) else { return }
                        Task { @MainActor in
                            guard progressAdmission.isCurrent(sample) else { return }
                            ref.model?.updateDownloadProgress(sample.fraction, for: item, generation: generation)
                        }
                    }
                )
                full = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                data = nil
            } else {
                let original = try await media.originalData(for: item.uid) { p in
                    guard let sample = progressAdmission.admit(p) else { return }
                    Task { @MainActor in
                        guard progressAdmission.isCurrent(sample) else { return }
                        ref.model?.updateDownloadProgress(sample.fraction, for: item, generation: generation)
                    }
                }
                data = original
                full =
                    expecting != .video
                    ? await Task.detached(priority: .userInitiated) {
                        Self.decodeFullImage(original, maxPixelSize: maxPixelSize)
                    }.value
                    : nil
            }
            guard !Task.isCancelled, originalLoadGeneration == generation,
                self.isDisplaying(item), self.sessionIsCurrent()
            else { return }
            isLoadingOriginal = false
            if let full {
                image = full
                isSharp = true
                loadedSharpPixelSize = max(loadedSharpPixelSize, targetPixelSize)
                requestedSharpPixelSize = loadedSharpPixelSize
                originalLoadFailed = false
                video.reset()
                Self.cacheFullImage(full, pixelSize: loadedSharpPixelSize, for: item.uid)
                // The opt-in Offline Library path keeps the encrypted complete original. Default viewing uses
                // bounded streaming and never allocates this whole plaintext value.
                if let data, cacheOriginals, let oc = originalsCache, let originalWriterGeneration {
                    let uid = item.uid
                    let cap = originalsCapBytes
                    Task.detached {
                        guard oc.storeToDisk(data, for: uid, ifCurrent: originalWriterGeneration) == .stored else {
                            return
                        }
                        if let cap { _ = oc.enforceByteCap(cap, ifCurrent: originalWriterGeneration) }
                    }
                }
            } else {
                requestedSharpPixelSize = loadedSharpPixelSize
                originalLoadFailed = expecting != .video
                video.fail(.streamURLUnavailable, uid: item.uid)
                logViewer(item, strategy: "streamRequired", kind: .video)
            }
        } catch is CancellationError {
            guard originalLoadGeneration == generation else { return }
            isLoadingOriginal = false
            requestedSharpPixelSize = loadedSharpPixelSize
        } catch {
            guard originalLoadGeneration == generation else { return }
            isLoadingOriginal = false
            requestedSharpPixelSize = loadedSharpPixelSize
            originalLoadFailed = expecting != .video
            if expecting == .video {
                video.fail(.classify(error), uid: item.uid)
                logViewer(item, strategy: "streamRequired", kind: .video)
            }
            // Image case: keep showing the best interim image (thumbnail/preview).
        }
    }

    private func cachedOriginalImage(
        for item: PhotoItem,
        maxPixelSize: Int?,
        writerGeneration: CacheWriterGeneration.Token?
    ) async -> NSImage? {
        guard let originalsCache, let writerGeneration else { return nil }
        let uid = item.uid
        let cached = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard originalsCache.isCurrentWriterGeneration(writerGeneration),
                let data = originalsCache.diskData(for: uid),
                let image = Self.decodeFullImage(data, maxPixelSize: maxPixelSize),
                originalsCache.isCurrentWriterGeneration(writerGeneration)
            else { return nil }
            _ = originalsCache.touch(uid, ifCurrent: writerGeneration)
            return image
        }.value
        guard !Task.isCancelled, isDisplaying(item), sessionIsCurrent(),
            originalsCache.isCurrentWriterGeneration(writerGeneration)
        else { return nil }
        return cached
    }

    /// Requests a bounded sharp representation after the user zooms. Page appearance never calls this method.
    public func requestOriginal(maxPixelSize: Int? = ViewerImageLoadPolicy.maxZoomedPixelSize) {
        let item = current
        let requested = maxPixelSize ?? .max
        guard !item.isVideo, sessionIsCurrent(), loadedSharpPixelSize < requested,
            requestedSharpPixelSize < requested
        else { return }
        requestedSharpPixelSize = requested
        // Invalidate the smaller in-flight load before cancellation reaches its progress and completion callbacks.
        originalLoadGeneration &+= 1
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.loadOriginalBytes(
                for: item,
                expecting: .image,
                maxPixelSize: maxPixelSize,
                useOfflineOriginalCache: true
            )
        }
    }

    /// Re-runs resolution for the current item (the "Retry" button in the failure overlay).
    public func retry() {
        guard current.isVideo || videoState.error != nil else { return }
        loadDisplayedItem(current)
    }

    /// Pushes real download progress into the state (used by the `@Sendable` progress callback via a
    /// weak box, so the callback never captures the non-Sendable view model directly).
    private func updateDownloadProgress(_ p: Double, for item: PhotoItem, generation: UInt64) {
        guard originalLoadGeneration == generation, current.uid == item.uid else { return }
        originalProgress = p
        if case .downloading = videoState { video.setDownloading(p) }
    }

    private func logViewer(_ item: PhotoItem, strategy: String, kind: MediaKind?) {
        PhotoDiagnostics.shared.emit(
            "VideoViewer",
            videoViewerLogFields(
                uid: item.uid,
                mime: item.mediaType,
                detectedKind: kind,
                state: videoState,
                strategy: strategy,
                localURLExists: false,
                assetPlayable: player?.currentItem?.status == .readyToPlay,
                playerItemStatus: player?.currentItem?.status.rawValue ?? 0,
                error: nil
            ))
    }
}

/// Sendable weak handle to the (MainActor, non-Sendable) view model, so the AVFoundation progress +
/// KVO `@Sendable` callbacks can route back to it without capturing it directly under Swift 6
/// concurrency. All access happens inside a `@MainActor` Task.
private final class WeakViewerRef: @unchecked Sendable {
    weak var model: PhotoViewerModel?
    init(_ model: PhotoViewerModel) { self.model = model }
}
