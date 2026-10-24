import Foundation
import UploadCore

/// Supplies pending-tile metadata from the photo-library catalog, without PhotoKit or media bytes.
public struct PhotoLibraryPendingMetadataProvider: PendingSourceMetadataProviding {
    private static let pageSize = 500

    private let catalog: PhotoLibraryCatalogManifestStore

    public init(catalog: PhotoLibraryCatalogManifestStore) {
        self.catalog = catalog
    }

    public func metadata(for keys: [PendingSourceKey]) async -> [PendingSourceKey: PendingPresentationMetadata] {
        let identifiers = keys.filter { $0.kind == .photoLibraryAsset }.map(\.identifier)
        var result: [PendingSourceKey: PendingPresentationMetadata] = [:]
        result.reserveCapacity(identifiers.count)
        var start = 0
        while start < identifiers.count {
            let page = identifiers[start..<min(identifiers.count, start + Self.pageSize)]
            for (identifier, entry) in catalog.presentEntries(for: Array(page)) {
                result[PendingSourceKey(kind: .photoLibraryAsset, identifier: identifier)] = Self.metadata(for: entry)
            }
            start += Self.pageSize
            await Task.yield()
        }
        return result
    }

    /// The capture time is the value the resolver uploads (`creationDate ?? modificationDate`).
    static func metadata(for entry: PhotoLibraryCatalogEntry) -> PendingPresentationMetadata {
        let isVideo = entry.mediaKind == .video
        let primaryRoles: Set<String> =
            isVideo
            ? [PhotoBackupAssetInfo.Resource.Role.originalVideo.rawValue]
            : [PhotoBackupAssetInfo.Resource.Role.originalPhoto.rawValue]
        let primary = entry.resources.first { primaryRoles.contains($0.role) } ?? entry.resources.first
        return PendingPresentationMetadata(
            captureTime: entry.creationDate ?? entry.modificationDate ?? entry.firstSeenAt,
            mediaType: primary?.mimeType ?? (isVideo ? "video/quicktime" : "image/jpeg"),
            isLivePhoto: entry.isLivePhoto && !entry.livePlaybackOff,
            durationSeconds: isVideo && entry.durationSeconds > 0 ? entry.durationSeconds : nil,
            displayName: primary?.originalFilename ?? ""
        )
    }
}
