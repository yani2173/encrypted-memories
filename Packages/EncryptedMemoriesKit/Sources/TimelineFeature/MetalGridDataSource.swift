import AppKit
import CoreGraphics
import GridCore
import MediaCache
import MediaFeedCore
import PhotosCore
import TimelineCore

/// Supplies the grid structure, flat UID order, and decoded RAM images for GPU texture upload.
@MainActor
protocol MetalGridDataSource: AnyObject {
    var sectionCounts: [Int] { get }
    var flatUIDs: [PhotoUID] { get }
    /// Cheap "is a RAM image ready?" check (no decode/conversion) - drives upload selection.
    func hasImage(for uid: PhotoUID) -> Bool
    /// True when a missing thumbnail can still make progress through disk/network/decode. Backend-refused
    /// thumbnails draw as stable placeholders and must not keep the display link or warm queue alive.
    func canRetryThumbnail(for uid: PhotoUID) -> Bool
    /// Synchronous in-RAM image for `uid`, or nil if not yet available (caller draws a placeholder).
    /// Only called for the bounded set of UIDs actually being uploaded this frame.
    func image(for uid: PhotoUID) -> CGImage?
    /// Prime visible placeholders into RAM (off-main) at the grid's measured upload size.
    func warm(_ requests: [ThumbnailRequest])
    /// Decode the given UIDs into RAM as a prefetch independent of moving-viewport demand. Lets a pinch's target
    /// level be warmed at segment-build time. Default: no-op.
    func prefetchWarm(_ uids: [PhotoUID])
    /// Main-actor notification after an async warm pass may have made new RAM images visible.
    var onImagesAvailable: (() -> Void)? { get set }
    /// Shared duration/RAW metadata already mapped into GridCore's platform-neutral overlay value.
    func thumbnailOverlay(for uid: PhotoUID) -> GridThumbnailOverlay
    /// Resolve metadata omitted by the lightweight timeline only for the resident visible window.
    func resolveOverlays(for uids: [PhotoUID])
    /// Replaces the upload badges of pending photos and of Proton photos that just took over from one.
    func updateUploadBadges(_ badges: PendingUploadBadges)
    /// The viewport needs no more thumbnails; loads it asked for earlier may stop.
    func endVisibleDemand()
    /// The grid left the screen: its local downloads stop.
    func retireLocalDemand()
    /// Reports real pointer/gesture interaction of one grid host to shared background scheduling. A mounted
    /// grid or outstanding thumbnail request is not interaction. The owner scopes the report so several
    /// windows over one feed never clear each other's live gesture.
    func setUserInteractionActive(_ active: Bool, owner: ThumbnailInteractionOwner)
}

extension MetalGridDataSource {
    func thumbnailOverlay(for uid: PhotoUID) -> GridThumbnailOverlay { .empty }
    func updateUploadBadges(_ badges: PendingUploadBadges) {}
    func endVisibleDemand() {}
    func retireLocalDemand() {}
    func resolveOverlays(for uids: [PhotoUID]) {}
    func canRetryThumbnail(for uid: PhotoUID) -> Bool { true }
    func prefetchWarm(_ uids: [PhotoUID]) {}  // only the real source decodes; test sources opt out
    func setUserInteractionActive(_ active: Bool, owner: ThumbnailInteractionOwner) {}
}

// MARK: - Real data (ThumbnailFeed-backed)

/// Reads the live library: decoded images come from the shared `ThumbnailFeed` (RAM-hit only on the render
/// thread; disk/network decode stays in the shared feed Core). `warm` replaces the current disk-only viewport
/// demand, while stable network admission remains separately debounced.
///
/// Production uses one continuous square-tile run.
///
/// Timeline sections feed date markers; `sectionCounts`
/// contains one count for the flattened UID order, or is empty for an empty library.
@MainActor
final class RealMetalGridDataSource: MetalGridDataSource {
    let sectionCounts: [Int]
    let flatUIDs: [PhotoUID]
    var onImagesAvailable: (() -> Void)?
    private let feed: ThumbnailFeed
    private let metadataProvider: (any PhotoMetadataProvider)?
    private let overlayResolver: TimelineThumbnailOverlayResolver
    private var prefetchTask: Task<Void, Never>?
    private var imagesAvailableWakeRegistration: ThumbnailFeedWakeRegistration?
    /// Coalesces network reprioritization for stable viewports while keeping local decoding immediate.
    private let networkDebouncer = ViewportRequestDebouncer(window: 0.1)
    private var settleCheckScheduled = false

    init(
        sections: [TimelineSection],
        feed: ThumbnailFeed,
        metadataProvider: (any PhotoMetadataProvider)? = nil
    ) {
        let items = sections.flatMap(\.items)
        let uids = items.map(\.uid)
        self.flatUIDs = uids
        self.sectionCounts = uids.isEmpty ? [] : [uids.count]  // one continuous section (production photo wall)
        self.feed = feed
        self.metadataProvider = metadataProvider
        self.overlayResolver = TimelineThumbnailOverlayResolver(items: items)
        self.overlayResolver.onChange = { [weak self] in self?.onImagesAvailable?() }
        self.imagesAvailableWakeRegistration = self.feed.feedCore.setOnImagesAvailableWake { [weak self] in
            Task { @MainActor [weak self] in
                self?.onImagesAvailable?()
            }
        }
    }

    deinit {
        imagesAvailableWakeRegistration?.end()
    }

    func thumbnailOverlay(for uid: PhotoUID) -> GridThumbnailOverlay {
        overlayResolver.overlay(for: uid)
    }

    func endVisibleDemand() {
        feed.submitVisibleDiskDecodeDemand([])
    }

    func retireLocalDemand() {
        let feedCore = feed.feedCore
        Task { await feedCore.endLocalVisibleDemand() }
    }

    func updateUploadBadges(_ badges: PendingUploadBadges) {
        overlayResolver.updateUploadBadges(badges)
    }

    func resolveOverlays(for uids: [PhotoUID]) {
        guard let metadataProvider else { return }
        overlayResolver.noteVisible(uids, metadataProvider: metadataProvider)
    }

    func setUserInteractionActive(_ active: Bool, owner: ThumbnailInteractionOwner) {
        feed.setUserInteractionActive(active, owner: owner)
    }

    func hasImage(for uid: PhotoUID) -> Bool { feed.memoryCGImage(for: uid) != nil }

    func canRetryThumbnail(for uid: PhotoUID) -> Bool {
        !feed.isKnownUnfetchable(uid)
    }

    func image(for uid: PhotoUID) -> CGImage? {
        feed.memoryCGImage(for: uid)
    }

    /// Anticipatory decode of an entire target set into RAM, independent of moving-viewport demand. Used to warm
    /// a pinch's target level at segment-build time. Idempotent; rapid level-chaining cancels the superseded ask.
    func prefetchWarm(_ uids: [PhotoUID]) {
        guard !uids.isEmpty else { return }
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self, feed] in
            _ = await feed.warmDecoded(uids, limit: uids.count)
            if Task.isCancelled { return }
            await MainActor.run { self?.onImagesAvailable?() }
        }
    }

    func warm(_ requests: [ThumbnailRequest]) {
        var incomingSeen = Set<PhotoUID>()
        var duplicateFiltered = 0
        var residentFiltered = 0
        var unfetchableFiltered = 0
        let incoming = requests.filter { request in
            guard incomingSeen.insert(request.uid).inserted else {
                duplicateFiltered += 1
                return false
            }
            guard feed.memoryCGImage(for: request.uid) == nil else {
                residentFiltered += 1
                return false
            }
            guard !feed.isKnownUnfetchable(request.uid) else {
                unfetchableFiltered += 1
                return false
            }
            return true
        }
        feed.submitVisibleDiskDecodeDemand(incoming)
        PhotoDiagnostics.shared.emitDebug(
            "ThumbSchedule",
            [
                "action": incoming.isEmpty ? "warmEmpty" : "warm",
                "requested": "\(requests.count)",
                "incoming": "\(incoming.count)",
                "duplicates": "\(duplicateFiltered)",
                "residentFiltered": "\(residentFiltered)",
                "unfetchableFiltered": "\(unfetchableFiltered)",
            ], throttleSeconds: 0.10, throttleKey: "warm")
        // Empty demand also replaces the prior network viewport so a route/geometry transition cannot later
        // enqueue thumbnails that are no longer visible.
        networkDebouncer.note(incoming.map(\.uid), at: CACurrentMediaTime())
        scheduleSettleCheck()
        guard !incoming.isEmpty else { return }
        // Record demand synchronously before any actor hop so the background crawl yields immediately.
        feed.noteVisibleDemand()
    }

    /// After the debounce window, if the viewport has settled, enqueue the still-missing visible cells at
    /// `.visibleNow` so they interrupt the crawl. Self-terminating: re-arms only while the viewport is still
    /// in flux. Disk decode remains immediate and independent of this network boundary.
    private func scheduleSettleCheck() {
        guard !settleCheckScheduled else { return }
        settleCheckScheduled = true
        let window = networkDebouncer.settleWindow
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(window + 0.02))
            guard let self else { return }
            self.settleCheckScheduled = false
            guard let settled = self.networkDebouncer.flushIfStable(at: CACurrentMediaTime()) else {
                // Re-arm from the debouncer's pending state so a fast scroll's final viewport is emitted even
                // when no later display-link tick arrives.
                if self.networkDebouncer.hasPendingUnflushed() { self.scheduleSettleCheck() }
                return
            }
            let missing = settled.filter {
                self.feed.memoryCGImage(for: $0) == nil && !self.feed.isKnownUnfetchable($0)
            }
            PhotoDiagnostics.shared.emitDebug(
                "ThumbSchedule",
                [
                    "action": "settled",
                    "settled": "\(settled.count)",
                    "missing": "\(missing.count)",
                ], throttleSeconds: 0.10, throttleKey: "settled")
            Task { [feed = self.feed] in
                _ = await feed.replaceVisiblePriorityDemand(missing)
            }
        }
    }
}
