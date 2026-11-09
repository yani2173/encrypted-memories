#if canImport(UIKit)
    import Foundation
    import MediaByteCache
    import MediaCacheCore
    import MediaDecodingCore
    import MediaFeedCore
    import PhotosCore
    import UIKit

    /// iOS/iPadOS thumbnail feed adapter.
    ///
    /// `ThumbnailFeedCore` remains the universal cache/feed implementation. This facade only adapts decoded
    /// `CGImage` residency to `UIImage` and injects conservative mobile RAM/concurrency policy.
    public actor UIKitThumbnailFeed {
        public typealias PrefetchStatus = ThumbnailFeedCore.PrefetchStatus

        private nonisolated let core: ThumbnailFeedCore
        private nonisolated let imageWrappers: WrapperImageCache<UIImage>

        /// The universal feed core, for shared consumers that must stay platform-neutral
        /// (Smart Search indexing reads cached thumbnails through it).
        public nonisolated var feedCore: ThumbnailFeedCore { core }

        public init(
            cache: ThumbnailCache,
            loader: ThumbnailBatchLoader,
            targetPixels: CGFloat = 320,
            concurrency: Int = UIKitMediaCachePolicy.downloadConcurrencyLimit(),
            batch: Int = 6,
            clock: @escaping @Sendable () -> Date = { Date() }
        ) {
            let configuration = ThumbnailFeedCoreConfiguration(
                targetPixels: targetPixels,
                downloadConcurrencyLimit: concurrency,
                initialDownloadConcurrency: max(1, concurrency / 2),
                minimumDownloadConcurrency: 1,
                batchSize: batch,
                decodedMemoryBudgetBytes: UIKitMediaCachePolicy.decodedRAMBudgetBytes(),
                maxConcurrentDecodes: UIKitMediaCachePolicy.maxConcurrentDecodes(),
                priorityQueueLimit: 360,
                sequentialScanLimit: 80,
                visibleQuietWindow: 0.25,
                crawlBackoffSeconds: 5,
                downloadTimeoutSeconds: 20
            )
            let wrappers = WrapperImageCache<UIImage>(
                countLimit: 256,
                costLimitBytes: UIKitMediaCachePolicy.wrapperRAMBudgetBytes()
            )
            imageWrappers = wrappers
            self.core = ThumbnailFeedCore(
                cache: cache,
                loader: loader,
                configuration: configuration,
                coverageStore: FileThumbnailCoverageCheckpointStore(
                    directory: cache.coverageCheckpointDirectory(),
                    scope: cache.coverageCheckpointScope()
                ),
                clock: clock
            )
        }

        /// Governor-driven memory-pressure response for both iOS RAM tiers this adapter owns: the UIImage
        /// wrappers here and the shared decoded-CGImage tier in the core. `scale` lowers each cost limit;
        /// `purge` drops held images now. `nonisolated` + thread-safe caches, so the governor never hops this
        /// actor. Nothing is lost - wrappers rebuild from the decoded tier, decodes from the encrypted disk tier.
        public nonisolated func applyMemoryPressure(scale: Double, purge: Bool) {
            imageWrappers.applyMemoryPressure(scale: scale, purge: purge)
            core.applyDecodedMemoryPressure(scale: scale, purge: purge)
        }

        public func cachedImage(for uid: PhotoUID) async -> UIImage? {
            let ticket = imageWrappers.captureTicket()
            guard await core.cachedDecoded(for: uid) != nil else { return nil }
            return currentImage(for: uid, ticket: ticket)
        }

        public nonisolated func memoryImage(for uid: PhotoUID) -> UIImage? {
            let ticket = imageWrappers.captureTicket()
            return currentImage(for: uid, ticket: ticket)
        }

        public nonisolated func memoryCGImage(for uid: PhotoUID) -> CGImage? {
            core.memoryDecoded(for: uid)?.image
        }

        /// See `ThumbnailFeedCore.decodedNeedsSharperSource` - true only for a present-but-undersized RAM decode.
        public nonisolated func decodedNeedsSharperSource(_ uid: PhotoUID, forPixels pixels: Int) -> Bool {
            core.decodedNeedsSharperSource(uid, forPixels: pixels)
        }

        public nonisolated func isKnownUnfetchable(_ uid: PhotoUID) -> Bool {
            core.isKnownUnfetchable(uid)
        }

        public func cacheState(
            for request: ThumbnailRequest, gpuTextureResident: Bool = false
        ) async -> ThumbnailCacheTierState {
            await core.cacheState(for: request, gpuTextureResident: gpuTextureResident)
        }

        public func requestPriority(_ uid: PhotoUID, priority requestedPriority: ThumbnailPriority = .visibleNow) async
        {
            await core.requestPriority(uid, priority: requestedPriority)
        }

        /// Fires when downloaded thumbnail bytes become durable in the encrypted cache. A view whose request
        /// returned no image subscribes and requests again, so it never stays empty until it is recreated.
        public nonisolated func setOnCacheArrivalWake(
            _ callback: @escaping @Sendable () -> Void
        ) -> ThumbnailFeedWakeRegistration {
            core.setOnCacheArrivalWake(callback)
        }

        public func hasRecentVisibleDemand(within: TimeInterval = 2.0) async -> Bool {
            core.hasRecentVisibleDemand(within: within)
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

        public func warmDecoded(_ uids: [PhotoUID], limit: Int = 120) async -> WarmDecodedResult {
            await core.warmDecoded(uids, limit: limit)
        }

        public func image(for uid: PhotoUID) async -> UIImage? {
            let ticket = imageWrappers.captureTicket()
            guard await core.decoded(for: uid) != nil else { return nil }
            return currentImage(for: uid, ticket: ticket)
        }

        public func analysisImage(for uid: PhotoUID) async -> UIImage? {
            guard let decoded = await core.analysisDecoded(for: uid) else { return nil }
            return UIKitThumbnailImageDecoder.image(from: decoded)
        }

        public func startPrefetch(_ uids: [PhotoUID]) async {
            await core.startPrefetch(uids)
        }

        public func waitForPrefetchToFinish() async throws {
            try await core.waitForPrefetchToFinish()
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
            ticket: WrapperImageCache<UIImage>.InsertionTicket
        ) -> UIImage? {
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
                    UIKitThumbnailImageDecoder.image(from: decoded)
                }
            )
        }
    }

    public extension UIKitThumbnailFeed {
        func libraryUpdateResolution(
            for uids: [PhotoUID],
            enqueueMissing: Bool
        ) async -> LibraryThumbnailResolutionSnapshot {
            await core.libraryUpdateResolution(for: uids, enqueueMissing: enqueueMissing)
        }
    }
#endif
