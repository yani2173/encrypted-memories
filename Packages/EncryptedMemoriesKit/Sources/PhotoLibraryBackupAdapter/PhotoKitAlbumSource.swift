import AlbumSyncCore
import Foundation
import Photos

/// `AlbumSyncLocalAlbumSource` over PhotoKit: user-created albums with stable identifiers, titles,
/// counts, sorted alphabetically by title. Metadata-only - no asset bytes, no thumbnails.
/// Callers ensure photo access first (`PhotoLibraryAuthorization`).
public struct PhotoKitAlbumSource: AlbumSyncLocalAlbumSource {
    /// Identifiers handed out per autorelease drain - bounds transient PhotoKit memory on large albums.
    private let chunkSize: Int

    public init(chunkSize: Int = 500) {
        self.chunkSize = max(1, chunkSize)
    }

    public func listAlbums() async throws -> [LocalAlbumSummary] {
        await Task.detached(priority: .utility) {
            let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            var result: [LocalAlbumSummary] = []
            result.reserveCapacity(collections.count)
            collections.enumerateObjects { collection, _, _ in
                // Only backupable media counts toward the album (mirrors the backup catalog).
                let options = PHFetchOptions()
                options.predicate = NSPredicate(
                    format: "mediaType == %d OR mediaType == %d",
                    PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
                )
                let count = PHAsset.fetchAssets(in: collection, options: options).count
                result.append(
                    LocalAlbumSummary(
                        id: collection.localIdentifier,
                        title: collection.localizedTitle ?? "",
                        assetCount: count
                    ))
            }
            // Alphabetical for a stable Settings list (PhotoKit exposes no cross-folder user order).
            return result.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }.value
    }

    public func albumContents(albumID: String) async throws -> AlbumSyncLocalAlbumContents {
        let chunk = chunkSize
        return await Task.detached(priority: .utility) {
            let collections = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [albumID], options: nil
            )
            guard let collection = collections.firstObject else { return .missing }
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
            )
            // No sort descriptors: PhotoKit returns the album's own (user-arranged) order.
            let assets = PHAsset.fetchAssets(in: collection, options: options)
            var identifiers: [String] = []
            identifiers.reserveCapacity(assets.count)
            var index = 0
            while index < assets.count {
                let upperBound = min(index + chunk, assets.count)
                autoreleasepool {
                    for position in index..<upperBound {
                        identifiers.append(assets.object(at: position).localIdentifier)
                    }
                }
                index = upperBound
            }
            return .present(identifiers)
        }.value
    }

    public func albumExists(albumID: String) async throws -> Bool {
        await Task.detached(priority: .utility) {
            PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [albumID], options: nil
            ).firstObject != nil
        }.value
    }
}
