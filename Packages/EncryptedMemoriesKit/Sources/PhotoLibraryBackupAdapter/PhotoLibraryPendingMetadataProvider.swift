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
        await metadataAnswer(for: keys).metadata
    }

    /// Each photo is its own catalog read: a row that cannot be read is unknown and leaves the others known (#1004).
    public func metadataAnswer(for keys: [PendingSourceKey]) async -> PendingSourceMetadataAnswer {
        let identifiers = keys.filter { $0.kind == .photoLibraryAsset }.map(\.identifier)
        var answer = PendingSourceMetadataAnswer()
        answer.metadata.reserveCapacity(identifiers.count)
        var start = 0
        while start < identifiers.count {
            let page = identifiers[start..<min(identifiers.count, start + Self.pageSize)]
            let presence = catalog.presence(for: Array(page))
            for (identifier, entry) in presence.present {
                answer.metadata[PendingSourceKey(kind: .photoLibraryAsset, identifier: identifier)] =
                    Self.metadata(for: entry)
            }
            answer.unknown.formUnion(
                presence.unknown.map { PendingSourceKey(kind: .photoLibraryAsset, identifier: $0) })
            start += Self.pageSize
            await Task.yield()
        }
        return answer
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
