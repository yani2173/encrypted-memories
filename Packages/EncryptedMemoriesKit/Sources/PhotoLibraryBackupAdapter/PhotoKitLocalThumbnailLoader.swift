import CoreGraphics
import Foundation
import MediaDecodingCore
import MediaFeedCore
import Photos
import PhotosCore

/// Grid thumbnails of pending Apple Photos assets, straight from PhotoKit. No Proton request and no
/// encrypted disk copy: PhotoKit already caches its own thumbnails. Network access is allowed so an
/// iCloud-optimized library still shows its photos.
public struct PhotoKitLocalThumbnailLoader: LocalThumbnailLoading {
    private static let maxConcurrentRequests = 4
    /// How long a quick, lower-quality version of a new photo may wait for the final one. The camera still
    /// processes a new photo for a while and has only the quick version; its new revision brings the final one.
    private static let degradedGrace: TimeInterval = 0.3
    /// Photos taken this recently may still be in camera processing. Older ones wait for their final version,
    /// so an iCloud photo never keeps a blurry tile.
    private static let freshWindow: TimeInterval = 3600

    private let request: PhotoKitImageRequest
    private let onMissing: (@Sendable ([PhotoUID]) -> Void)?

    /// `onMissing` hears about photos that no longer exist in Apple Photos (deleted before their upload).
    public init(request: @escaping PhotoKitImageRequest, onMissing: (@Sendable ([PhotoUID]) -> Void)? = nil) {
        self.request = request
        self.onMissing = onMissing
    }

    /// A small thumbnail for a list row, such as the excluded photos in the Backup settings.
    public func listThumbnail(for uid: PhotoUID) async -> CGImage? {
        await thumbnails(for: [uid], maxPixelSize: 120)[uid]?.image
    }

    public func thumbnails(for uids: [PhotoUID], maxPixelSize: CGFloat) async -> [PhotoUID: DecodedThumbnail] {
        #if ENCRYPTED_MEMORIES_UPGRADE_TEST
            if UpgradeTestProbe.isRequested {
                return await UpgradeTestPhotoLibrary.thumbnails(for: uids, maxPixelSize: maxPixelSize)
            }
        #endif
        let identifiers = uids.compactMap { uid -> String? in
            uid.localPendingNamespace == .photoLibrary ? uid.nodeID : nil
        }
        guard !identifiers.isEmpty else { return [:] }
        let assets = await Task.detached(priority: .userInitiated) { () -> [PHAsset] in
            let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            var assets: [PHAsset] = []
            assets.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in assets.append(asset) }
            return assets
        }.value
        if let onMissing, assets.count < identifiers.count {
            let found = Set(assets.map(\.localIdentifier))
            let missing = identifiers.filter { !found.contains($0) }
            onMissing(missing.map { PhotoUID(localPending: .photoLibrary, identifier: $0) })
        }
        let side = max(1, maxPixelSize)
        return await withTaskGroup(of: (PhotoUID, DecodedThumbnail?).self) { group in
            var result: [PhotoUID: DecodedThumbnail] = [:]
            var next = 0
            func addNext() {
                guard next < assets.count, !Task.isCancelled else { return }
                let asset = assets[next]
                next += 1
                group.addTask { [request] in
                    let image = await Self.image(for: asset, side: side, request: request)
                    return (PhotoUID(localPending: .photoLibrary, identifier: asset.localIdentifier), image)
                }
            }
            for _ in 0..<min(Self.maxConcurrentRequests, assets.count) { addNext() }
            for await (uid, image) in group {
                if let image { result[uid] = image }
                addNext()
            }
            return result
        }
    }

    private static func image(
        for asset: PHAsset, side: CGFloat, request: PhotoKitImageRequest
    ) async -> DecodedThumbnail? {
        let options = PHImageRequestOptions()
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let size = CGSize(width: side, height: side)
        let isFresh = asset.creationDate.map { Date().timeIntervalSince($0) < freshWindow } ?? false
        guard isFresh else {
            options.deliveryMode = .highQualityFormat
            return await PhotoKitRequest.perform { finish in
                // `.highQualityFormat` calls back exactly once.
                request(asset, size, .aspectFill, options) { image, _ in
                    finish(image.map(DecodedThumbnail.init(image:)))
                }
            }
        }
        // The quick version shows at once; the final one replaces it when it follows within the grace time.
        options.deliveryMode = .opportunistic
        let quick = QuickVersion()
        return await PhotoKitRequest.perform { finish in
            let id = request(asset, size, .aspectFill, options) { image, isDegraded in
                guard isDegraded else {
                    finish((image ?? quick.image).map(DecodedThumbnail.init(image:)))
                    return
                }
                guard let image, quick.keep(image) else { return }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + degradedGrace) {
                    finish(quick.image.map(DecodedThumbnail.init(image:)))
                    // The final version waits for the camera; the revision loads it. Keeps at most four requests.
                    quick.requestID.map(PHImageManager.default().cancelImageRequest)
                }
            }
            quick.requestID = id
            return id
        }
    }

    /// The first lower-quality version of one request.
    private final class QuickVersion: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CGImage?
        private var storedID: PHImageRequestID?

        var image: CGImage? { lock.withLock { stored } }

        var requestID: PHImageRequestID? {
            get { lock.withLock { storedID } }
            set { lock.withLock { storedID = newValue } }
        }

        /// True for the first version only.
        func keep(_ image: CGImage) -> Bool {
            lock.withLock {
                guard stored == nil else { return false }
                stored = image
                return true
            }
        }
    }
}
