import AppKit
import Foundation
import MediaByteCache
import MediaCacheCore
import MediaDecodingCore
import MediaFeedCore
import PhotosCore

/// macOS thumbnail feed adapter.
///
/// `ThumbnailFeedCore` owns the universal feed behavior: priority, prefetch, disk/network decisions, adaptive
/// concurrency, decoded `CGImage` residency, and diagnostics. This facade preserves the existing macOS `NSImage`
/// API for Timeline, Viewer, and Filmstrip while keeping AppKit outside the shared feed core.
public actor ThumbnailFeed {
    public typealias PrefetchStatus = ThumbnailFeedCore.PrefetchStatus

    private nonisolated let core: ThumbnailFeedCore
    private nonisolated let imageWrappers: WrapperImageCache<NSImage>

    /// The universal feed core, for shared consumers that must stay platform-neutral
    /// (Smart Search indexing reads cached thumbnails through it).
    public nonisolated var feedCore: ThumbnailFeedCore { core }

    public init(
        cache: ThumbnailCache,
        loader: ThumbnailBatchLoader,
        targetPixels: CGFloat = 320,
        concurrency: Int = 10,
        batch: Int = 8,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            cache: cache,
            loader: loader,
            targetPixels: targetPixels,
            concurrency: concurrency,
            batch: batch,
            diagnostics: .shared,
            clock: clock
        )
    }

    public init(
        cache: ThumbnailCache,
        loader: ThumbnailBatchLoader,
        targetPixels: CGFloat = 320,
        concurrency: Int = 10,
        batch: Int = 8,
        diagnostics: PhotoDiagnostics,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        let configuration = ThumbnailFeedCoreConfiguration(
            targetPixels: targetPixels,
            downloadConcurrencyLimit: concurrency,
            initialDownloadConcurrency: max(2, concurrency / 2),
            minimumDownloadConcurrency: 2,
            batchSize: batch,
            decodedMemoryBudgetBytes: Self.decodedRAMBudgetBytes(),
            maxConcurrentDecodes: max(1, ProcessInfo.processInfo.activeProcessorCount),
            priorityQueueLimit: 600,
            sequentialScanLimit: 128,
            visibleQuietWindow: 0.25,
            crawlBackoffSeconds: 5,
            downloadTimeoutSeconds: 20
        )
        let wrappers = WrapperImageCache<NSImage>(countLimit: 512, costLimitBytes: Self.wrapperRAMBudgetBytes())
        self.imageWrappers = wrappers
        self.core = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: configuration,
            coverageStore: FileThumbnailCoverageCheckpointStore(
                directory: cache.coverageCheckpointDirectory(),
                scope: cache.coverageCheckpointScope()
            ),
            diagnostics: diagnostics,
            clock: clock
        )
    }

    static func decodedRAMBudgetBytes() -> Int {
        let physical = Double(ProcessInfo.processInfo.physicalMemory)
        let floor = 256.0 * 1024 * 1024
        let ceiling = 20.0 * 1024 * 1024 * 1024
        return Int(min(max(physical * 0.15, floor), ceiling))
    }

    static func wrapperRAMBudgetBytes() -> Int {
        let physical = Double(ProcessInfo.processInfo.physicalMemory)
        let floor = 16.0 * 1024 * 1024
        let ceiling = 96.0 * 1024 * 1024
        return Int(min(max(physical * 0.005, floor), ceiling))
    }

    /// Governor-driven memory-pressure response for both macOS RAM tiers this adapter owns: the AppKit
    /// NSImage wrappers here and the shared decoded-CGImage tier in the core. `scale` lowers each cost
    /// limit; `purge` drops held images now. `nonisolated` + thread-safe NSCaches, so the governor never
    /// hops this actor. Nothing is lost - wrappers rebuild from the decoded tier, decodes from disk.
    public nonisolated func applyMemoryPressure(scale: Double, purge: Bool) {
        imageWrappers.applyMemoryPressure(scale: scale, purge: purge)
        core.applyDecodedMemoryPressure(scale: scale, purge: purge)
    }

    public func cachedImage(for uid: PhotoUID) async -> NSImage? {
        let ticket = imageWrappers.captureTicket()
        guard await core.cachedDecoded(for: uid) != nil else { return nil }
        return currentImage(for: uid, ticket: ticket)
    }

    public nonisolated func memoryImage(for uid: PhotoUID) -> NSImage? {
        let ticket = imageWrappers.captureTicket()
        return currentImage(for: uid, ticket: ticket)
    }

    public nonisolated func memoryCGImage(for uid: PhotoUID) -> CGImage? {
        core.memoryDecoded(for: uid)?.image
    }

    public nonisolated func isKnownUnfetchable(_ uid: PhotoUID) -> Bool {
        core.isKnownUnfetchable(uid)
    }

    public func cacheState(
        for request: ThumbnailRequest, gpuTextureResident: Bool = false
    ) async -> ThumbnailCacheTierState {
        await core.cacheState(for: request, gpuTextureResident: gpuTextureResident)
    }

    public func requestPriority(_ uid: PhotoUID, priority requestedPriority: ThumbnailPriority = .visibleNow) async {
        await core.requestPriority(uid, priority: requestedPriority)
    }

    @discardableResult
    public func replaceVisiblePriorityDemand(_ orderedUIDs: [PhotoUID]) async -> Int {
        await core.replaceVisiblePriorityDemand(orderedUIDs)
    }

    public func hasRecentVisibleDemand(within: TimeInterval = 2.0) async -> Bool {
        core.hasRecentVisibleDemand(within: within)
    }

    public nonisolated func noteVisibleDemand() {
        core.noteVisibleDemand()
    }

    public func hasPendingThumbnailWork() async -> Bool {
        await core.hasPendingThumbnailWork()
    }

    /// Visible-only pressure (priority queue / live viewport demand) - excludes the whole-library
    /// sequential fill. The Map's GPS crawl yields on this, never on full crawl completion.
    public func hasVisibleThumbnailPressure() async -> Bool {
        await core.hasVisibleThumbnailPressure()
    }

    public func warmDecoded(
        _ requests: [ThumbnailRequest],
        priority requestedPriority: ThumbnailPriority,
        limit: Int
    ) async -> WarmDecodedResult {
        await core.warmDecoded(requests, priority: requestedPriority, limit: limit)
    }

    public func warmVisibleDecoded(
        _ requests: [ThumbnailRequest],
        limit: Int
    ) async -> WarmDecodedResult {
        await core.warmVisibleDecoded(requests, limit: limit)
    }

    public nonisolated func submitVisibleDiskDecodeDemand(
        _ requests: [ThumbnailRequest]
    ) {
        core.submitVisibleDiskDecodeDemand(requests)
    }

    public func warmDecoded(_ uids: [PhotoUID], limit: Int = 160) async -> WarmDecodedResult {
        await core.warmDecoded(uids, limit: limit)
    }

    public func image(for uid: PhotoUID) async -> NSImage? {
        let ticket = imageWrappers.captureTicket()
        guard await core.decoded(for: uid) != nil else { return nil }
        return currentImage(for: uid, ticket: ticket)
    }

    public func analysisImage(for uid: PhotoUID) async -> NSImage? {
        guard let decoded = await core.analysisDecoded(for: uid) else { return nil }
        return MacThumbnailImageDecoder.image(from: decoded)
    }

    public func startPrefetch(_ uids: [PhotoUID]) async {
        await core.startPrefetch(uids)
    }

    public func stopPrefetch() async {
        imageWrappers.invalidateAll()
        await core.stopPrefetchAndWait()
    }

    public func clearCacheAndRestartPrefetch() async {
        imageWrappers.invalidateAll()
        await core.clearCacheAndRestartPrefetch()
    }

    public func setPrefetchEnabled(_ enabled: Bool) async {
        await core.setPrefetchEnabled(enabled)
    }

    public func pausePrefetch() async {
        await core.pausePrefetch()
    }

    public func resumePrefetch() async {
        await core.resumePrefetch()
    }

    public nonisolated func setUserInteractionActive(_ active: Bool, owner: ThumbnailInteractionOwner) {
        core.setUserInteractionActive(active, owner: owner)
    }

    public func prefetchStatus() async -> PrefetchStatus {
        await core.prefetchStatus()
    }

    private nonisolated func currentImage(
        for uid: PhotoUID,
        ticket: WrapperImageCache<NSImage>.InsertionTicket
    ) -> NSImage? {
        guard let decoded = core.memoryDecoded(for: uid) else { return nil }
        let key = uid.cacheKey
        return imageWrappers.resolvePairedImage(
            forKey: key,
            cost: decoded.decodedCostBytes,
            source: decoded.image,
            ticket: ticket,
            sourceIsCurrent: { [core] in
                core.memoryDecoded(for: uid)?.image === decoded.image
            },
            build: {
                MacThumbnailImageDecoder.image(from: decoded)
            }
        )
    }
}

public extension ThumbnailFeed {
    func libraryUpdateResolution(
        for uids: [PhotoUID],
        enqueueMissing: Bool
    ) async -> LibraryThumbnailResolutionSnapshot {
        await core.libraryUpdateResolution(for: uids, enqueueMissing: enqueueMissing)
    }
}
