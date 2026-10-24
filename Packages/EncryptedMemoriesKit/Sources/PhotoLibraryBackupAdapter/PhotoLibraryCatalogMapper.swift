import Foundation
import UploadCore

/// Bridges the planner's PhotoKit-free `PhotoBackupAssetInfo` to the Core catalog's
/// `PhotoLibraryCatalogEntry`. Pure logic over plain values - no PhotoKit, no I/O - so the catalog's
/// change detection is fully testable off-device.
///
/// The catalog's two revision fields are deliberately the same values the backup planner uses:
/// `contentFingerprint` is the structural fingerprint (a metadata-only change never moves it) and
/// `metadataRevision` is the modification-date revision. This keeps "the catalog thinks it changed"
/// aligned with "the preflight would re-check it", so a catalogued change is a meaningful signal.
public enum PhotoLibraryCatalogMapper {
    public static func entry(for info: PhotoBackupAssetInfo, observedAt: Date) -> PhotoLibraryCatalogEntry {
        PhotoLibraryCatalogEntry(
            localIdentifier: info.localIdentifier,
            cloudIdentifier: info.cloudIdentifier,
            creationDate: info.creationDate,
            modificationDate: info.modificationDate,
            pixelWidth: info.pixelWidth,
            pixelHeight: info.pixelHeight,
            durationSeconds: info.durationSeconds,
            mediaKind: info.isVideo ? .video : .image,
            isLivePhoto: info.isLivePhoto,
            livePlaybackOff: info.livePlaybackOff,
            resources: info.resources.map {
                PhotoLibraryCatalogResource(
                    role: $0.role.rawValue,
                    originalFilename: $0.originalFilename,
                    mimeType: $0.mimeType,
                    ordinal: $0.ordinal
                )
            },
            contentFingerprint: PhotoBackupAssetPlanner.fingerprintRevision(for: info).rawValue,
            metadataRevision: PhotoBackupAssetPlanner.metadataRevision(for: info).rawValue,
            firstSeenAt: observedAt,
            lastSeenAt: observedAt
        )
    }

    /// Rehydrates the pure planning input from the durable inventory. This never reads PhotoKit or
    /// media bytes; it is used only to replay an incomplete queue after launch or an app upgrade.
    public static func info(for entry: PhotoLibraryCatalogEntry) -> PhotoBackupAssetInfo {
        var info = PhotoBackupAssetInfo(
            localIdentifier: entry.localIdentifier,
            creationDate: entry.creationDate,
            modificationDate: entry.modificationDate,
            pixelWidth: entry.pixelWidth,
            pixelHeight: entry.pixelHeight,
            durationSeconds: entry.durationSeconds,
            isLivePhoto: entry.isLivePhoto,
            isVideo: entry.mediaKind == .video,
            resources: entry.resources.map {
                PhotoBackupAssetInfo.Resource(
                    role: PhotoBackupAssetInfo.Resource.Role(rawValue: $0.role) ?? .other,
                    originalFilename: $0.originalFilename,
                    mimeType: $0.mimeType,
                    ordinal: $0.ordinal
                )
            },
            cloudIdentifier: entry.cloudIdentifier,
            livePlaybackOff: entry.livePlaybackOff
        )
        // The inventory does not store the adjustment state. Only an edit without its rendered file moves the
        // revision away from the one that the stored values give, and a replay must plan that same revision.
        if PhotoBackupAssetPlanner.metadataRevision(for: info).rawValue != entry.metadataRevision {
            info.hasAdjustments = true
        }
        return info
    }
}
