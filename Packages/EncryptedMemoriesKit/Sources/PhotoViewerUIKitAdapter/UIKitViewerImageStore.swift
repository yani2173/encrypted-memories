#if canImport(UIKit) && !os(watchOS)
    import Foundation
    import MediaCacheCore
    import os
    import PhotoViewerCore
    import PhotosCore
    import QuartzCore
    import UIKit

    /// Bounded viewer image cache.
    ///
    /// Shows the grid thumbnail immediately, then loads a screen-sized preview or
    /// original fallback. Memory pressure keeps the current page and releases non-visible images.
    @MainActor
    public final class UIKitViewerImageStore {
        public struct DisplayImage {
            public let image: UIImage
            public let source: String
            public let longestPixelSide: Int

            init(image: UIImage, source: String) {
                self.image = image
                self.source = source
                if let cgImage = image.cgImage {
                    longestPixelSide = max(cgImage.width, cgImage.height)
                } else {
                    longestPixelSide = Int(
                        (max(image.size.width, image.size.height) * max(1, image.scale)).rounded()
                    )
                }
            }
        }

        private static let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "ViewerPerf")
        #if DEBUG
            private static let verbose = true
        #else
            private static let verbose = false
        #endif

        private let thumbnailProvider: (PhotoUID) -> UIImage?
        /// The grid thumbnail from the feed's disk tier, for a photo whose RAM decode was evicted.
        private let cachedThumbnailProvider: (@MainActor (PhotoUID) async -> UIImage?)?
        private let media: (any FullMediaProvider)?
        /// Optional host-provided override for the original-bytes fallback. The host owns encrypted-original
        /// caching; when nil, the store uses `media.originalData`.
        private let originalDataOverride: (@Sendable (PhotoUID) async throws -> Data)?
        private let cache = WrapperImageCache<CachedDisplayImage>(countLimit: 8, costLimitBytes: 48 * 1024 * 1024)
        /// The page currently on screen, which a `.minimal` purge keeps. `displayImage` is called for the
        /// current page only (`ViewerImageLoadPolicy` gates neighbours), so recording it here is exact.
        private var currentPageUID: PhotoUID?

        public init(
            thumbnailProvider: @escaping (PhotoUID) -> UIImage?,
            cachedThumbnailProvider: (@MainActor (PhotoUID) async -> UIImage?)? = nil,
            media: (any FullMediaProvider)?,
            originalDataOverride: (@Sendable (PhotoUID) async throws -> Data)? = nil
        ) {
            self.thumbnailProvider = thumbnailProvider
            self.cachedThumbnailProvider = cachedThumbnailProvider
            self.media = media
            self.originalDataOverride = originalDataOverride
        }

        /// The instant grid thumbnail (already decoded in the feed's RAM tier), or nil.
        public func thumbnail(for uid: PhotoUID) -> DisplayImage? {
            thumbnailProvider(uid).map { DisplayImage(image: $0, source: "thumbnail") }
        }

        /// The grid thumbnail from disk when RAM no longer holds it. Never touches the network, so the viewer
        /// shows the photo at once instead of black until its preview arrives.
        public func cachedThumbnail(for uid: PhotoUID) async -> DisplayImage? {
            guard let cachedThumbnailProvider else { return nil }
            return await cachedThumbnailProvider(uid).map { DisplayImage(image: $0, source: "thumbnail") }
        }

        /// Governor-driven memory-pressure response. `scale` lowers the display cache's cost ceiling; `purge`
        /// drops every page except the current one, so the on-screen image never blanks under a memory warning.
        /// One `[ViewerPerf]` line per invocation - the governor only calls on tier CHANGES, so no log spam.
        public func applyMemoryPressure(scale: Double, purge: Bool) {
            let clamped = min(1, max(0, scale))
            let scaledLimit = Int(Double(cache.nominalCostLimitBytes) * clamped)
            if purge {
                let keptKey = currentPageUID.map(\.cacheKey)
                let keptCost = keptKey.flatMap { cache.image(forKey: $0)?.cost } ?? 0
                // Floor the shrunken limit at the kept page's cost so the on-screen entry survives its own
                // re-insert even at scale 0 - "keep only what is currently essential", which this page IS.
                cache.setCostLimit(max(scaledLimit, keptCost))
                cache.purge(keeping: keptKey, keptCost: keptCost)  // drop all non-visible pages
            } else {
                cache.setCostLimit(scaledLimit)
            }
            Self.logger.notice(
                """
                [ViewerPerf] cache pressure scale=\(String(format: "%.2f", scale), privacy: .public) \
                purge=\(purge) keptCurrent=\(self.currentPageUID != nil) \
                limitMB=\(self.cache.currentCostLimitBytes / 1_048_576)
                """)
        }

        /// Drops the kept images of photos whose content can differ from their last showing, such as the tile of
        /// a second edit that reuses the UID of the first. The next request loads them again.
        public func forget(_ uids: [PhotoUID]) {
            for uid in uids {
                cache.remove(forKey: uid.cacheKey)
                // A load that started before keeps its result out of the cache and away from the page.
                forgottenGenerations[uid, default: 0] &+= 1
            }
        }

        /// Counts `forget` calls per photo, so a load can tell that its bytes may belong to an earlier content.
        private var forgottenGenerations: [PhotoUID: UInt64] = [:]

        private func generation(of uid: PhotoUID) -> UInt64 {
            forgottenGenerations[uid] ?? 0
        }

        /// Loads a bounded display image from cache, preview bytes, or original bytes.
        /// Cancellation prevents an obsolete page from publishing its decode.
        public func displayImage(for uid: PhotoUID, maxPixelSize: Int) async -> DisplayImage? {
            let startGeneration = generation(of: uid)
            currentPageUID = uid
            let key = uid.cacheKey
            // Avoid reusing a thumbnail-sized decode for a later full-screen request.
            if let cached = cache.image(forKey: key), cached.decodedCap >= maxPixelSize {
                return DisplayImage(image: cached.image, source: cached.source)
            }
            guard let media else { return nil }

            let fetchStart = CACurrentMediaTime()
            if Self.verbose {
                Self.logger.notice("[ViewerPerf] preview fetch start uid=\(Self.short(uid), privacy: .public)")
            }
            let data: Data
            let source: String
            do {
                data = try await media.preview(for: uid)
                source = "preview"
            } catch {
                if Self.verbose {
                    Self.logger.notice(
                        "[ViewerPerf] preview fetch fail uid=\(Self.short(uid), privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                }
                guard !Task.isCancelled else {
                    if Self.verbose {
                        Self.logger.notice("[ViewerPerf] preview cancelled uid=\(Self.short(uid), privacy: .public)")
                    }
                    return nil
                }
                if media is any OriginalByteStreamProvider,
                    let image = await streamedImage(for: uid, maxPixelSize: maxPixelSize)
                {
                    guard !Task.isCancelled else { return nil }
                    return keep(
                        image, source: "originalFallbackStream", maxPixelSize: maxPixelSize, key: key, uid: uid,
                        startGeneration: startGeneration)
                }
                guard !Task.isCancelled else { return nil }
                if Self.verbose {
                    Self.logger.notice(
                        "[ViewerPerf] original fallback fetch start uid=\(Self.short(uid), privacy: .public)")
                }
                do {
                    // Cache-first + persisting when the host injected an override; otherwise the plain provider.
                    if let originalDataOverride {
                        data = try await originalDataOverride(uid)
                    } else {
                        data = try await media.originalData(for: uid)
                    }
                    source = "originalFallback"
                } catch {
                    if Self.verbose {
                        Self.logger.notice(
                            "[ViewerPerf] original fallback fail uid=\(Self.short(uid), privacy: .public) error=\(String(describing: error), privacy: .public)"
                        )
                    }
                    return nil
                }
            }
            if Task.isCancelled {
                if Self.verbose {
                    Self.logger.notice("[ViewerPerf] display fetch cancelled uid=\(Self.short(uid), privacy: .public)")
                }
                return nil
            }
            let fetchMs = (CACurrentMediaTime() - fetchStart) * 1000

            let decodeStart = CACurrentMediaTime()
            let image = await Task.detached(priority: .userInitiated) {
                UIKitViewerImageAdapter.image(from: data, maxPixelSize: maxPixelSize)
            }.value
            if Task.isCancelled { return nil }
            guard let image else {
                if Self.verbose {
                    Self.logger.notice("[ViewerPerf] decode fail uid=\(Self.short(uid), privacy: .public)")
                }
                return nil
            }
            let decodeMs = (CACurrentMediaTime() - decodeStart) * 1000
            guard
                let displayed = keep(
                    image, source: source, maxPixelSize: maxPixelSize, key: key, uid: uid,
                    startGeneration: startGeneration)
            else { return nil }
            if Self.verbose {
                let px = Self.pixelSize(of: image)
                Self.logger.notice(
                    """
                    [ViewerPerf] display ready uid=\(Self.short(uid), privacy: .public) source=\(source, privacy: .public) \
                    px=\(Int(px.width))x\(Int(px.height)) fetchMs=\(String(format: "%.0f", fetchMs), privacy: .public) \
                    decodeMs=\(String(format: "%.0f", decodeMs), privacy: .public) bytes=\(data.count)
                    """)
            }
            return displayed
        }

        /// Loads the original image tier, decoded off-main to the same bounded display size as previews.
        public func originalImage(for uid: PhotoUID, maxPixelSize: Int) async -> DisplayImage? {
            let startGeneration = generation(of: uid)
            currentPageUID = uid
            let key = uid.cacheKey
            // Reuse original-backed decodes only when they satisfy this request's size.
            if let cached = cache.image(forKey: key), cached.source.hasPrefix("original"),
                cached.decodedCap >= maxPixelSize
            {
                return DisplayImage(image: cached.image, source: cached.source)
            }

            if media is any OriginalByteStreamProvider,
                let image = await streamedImage(for: uid, maxPixelSize: maxPixelSize)
            {
                guard !Task.isCancelled else { return nil }
                return keep(
                    image, source: "original", maxPixelSize: maxPixelSize, key: key, uid: uid,
                    startGeneration: startGeneration)
            }
            guard !Task.isCancelled else { return nil }

            let fetchStart = CACurrentMediaTime()
            let data: Data
            do {
                // A failed stream can still be satisfied by the host's encrypted offline originals cache.
                // Fall back to the media provider only when the host has no override.
                if let originalDataOverride {
                    data = try await originalDataOverride(uid)
                } else if let media {
                    data = try await media.originalData(for: uid)
                } else {
                    return nil
                }
            } catch {
                if Self.verbose {
                    Self.logger.notice(
                        "[ViewerPerf] original fetch fail uid=\(Self.short(uid), privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                }
                return nil
            }
            if Task.isCancelled { return nil }
            let fetchMs = (CACurrentMediaTime() - fetchStart) * 1000

            let decodeStart = CACurrentMediaTime()
            let image = await Task.detached(priority: .userInitiated) {
                UIKitViewerImageAdapter.image(from: data, maxPixelSize: maxPixelSize)
            }.value
            if Task.isCancelled { return nil }
            guard let image else {
                if Self.verbose {
                    Self.logger.notice("[ViewerPerf] original decode fail uid=\(Self.short(uid), privacy: .public)")
                }
                return nil
            }
            let decodeMs = (CACurrentMediaTime() - decodeStart) * 1000
            guard
                let displayed = keep(
                    image, source: "original", maxPixelSize: maxPixelSize, key: key, uid: uid,
                    startGeneration: startGeneration)
            else { return nil }
            if Self.verbose {
                let px = Self.pixelSize(of: image)
                Self.logger.notice(
                    """
                    [ViewerPerf] original ready uid=\(Self.short(uid), privacy: .public) \
                    px=\(Int(px.width))x\(Int(px.height)) fetchMs=\(String(format: "%.0f", fetchMs), privacy: .public) \
                    decodeMs=\(String(format: "%.0f", decodeMs), privacy: .public) bytes=\(data.count)
                    """)
            }
            return displayed
        }

        /// Keeps a decode for the next request, unless `forget` ran for the photo after `startGeneration`: then the
        /// bytes may belong to earlier content, so nothing is cached and the caller shows nothing.
        private func keep(
            _ image: UIImage, source: String, maxPixelSize: Int, key: NSString, uid: PhotoUID,
            startGeneration: UInt64
        ) -> DisplayImage? {
            let px = Self.pixelSize(of: image)
            let cost = Int(px.width * px.height) * 4
            guard generation(of: uid) == startGeneration else { return nil }
            cache.set(
                CachedDisplayImage(image: image, source: source, cost: cost, decodedCap: maxPixelSize), forKey: key,
                cost: cost)
            return DisplayImage(image: image, source: source)
        }

        private static func pixelSize(of image: UIImage) -> CGSize {
            image.size.applying(CGAffineTransform(scaleX: image.scale, y: image.scale))
        }

        private func streamedImage(for uid: PhotoUID, maxPixelSize: Int) async -> UIImage? {
            guard let media, let provider = media as? any OriginalByteStreamProvider else { return nil }
            do {
                let cgImage = try await ViewerFullImageDecoder.decodeStreamedCGImage(
                    from: provider,
                    uid: uid,
                    maxPixelSize: maxPixelSize,
                    onProgress: { _ in }
                )
                return cgImage.map { UIKitViewerImageAdapter.image(from: $0) }
            } catch {
                return nil
            }
        }

        private static func short(_ uid: PhotoUID) -> String {
            String(uid.nodeID.suffix(6))
        }
    }

    private final class CachedDisplayImage {
        let image: UIImage
        let source: String
        let cost: Int
        /// Pixel cap used for the decode.
        let decodedCap: Int

        init(image: UIImage, source: String, cost: Int, decodedCap: Int) {
            self.image = image
            self.source = source
            self.cost = cost
            self.decodedCap = decodedCap
        }
    }
#endif
