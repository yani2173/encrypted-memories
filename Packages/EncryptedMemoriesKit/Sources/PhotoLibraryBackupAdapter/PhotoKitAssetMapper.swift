import Foundation
import Photos
import UniformTypeIdentifiers

/// The only place PhotoKit types become `PhotoBackupAssetInfo`. Reads local metadata only -
/// `PHAssetResource.assetResources(for:)` is synchronous and never triggers downloads.
enum PhotoKitAssetMapper {
    /// The asset as backup sees it. A photo of a burst (series) also carries its series role, so that only
    /// the series' main photo becomes a backup candidate and its members travel in that compound.
    static func info(for asset: PHAsset, cloudIdentifier: String? = nil) -> PhotoBackupAssetInfo {
        var plans = BurstPlanCache()
        return info(for: asset, cloudIdentifier: cloudIdentifier, plans: &plans)
    }

    /// Plans of the series already seen in this batch, keyed by burst identifier. PhotoKit surfaces the
    /// representative and every user pick of one series as separate assets, so a batch asks for the same
    /// plan several times. One fetch per series replaces one fetch per asset.
    typealias BurstPlanCache = [String: PhotoBurstUploadPlan?]

    private static func info(
        for asset: PHAsset,
        cloudIdentifier: String?,
        plans: inout BurstPlanCache
    ) -> PhotoBackupAssetInfo {
        let info = assetInfo(for: asset, cloudIdentifier: cloudIdentifier)
        guard let burstIdentifier = asset.burstIdentifier else { return info }
        let plan: PhotoBurstUploadPlan?
        if let cached = plans[burstIdentifier] {
            plan = cached
        } else {
            plan = burstPlan(withBurstIdentifier: burstIdentifier)
            plans[burstIdentifier] = plan
        }
        guard let plan else { return info }
        return PhotoBurstUploadPlanner.applying(plan, to: info)
    }

    /// Fetches every photo of the asset's series, including the ones PhotoKit hides by default, and plans
    /// the upload. Nil for an asset outside a series. Metadata only; never downloads bytes.
    static func burstPlan(for asset: PHAsset) -> PhotoBurstUploadPlan? {
        guard let burstIdentifier = asset.burstIdentifier else { return nil }
        return burstPlan(withBurstIdentifier: burstIdentifier)
    }

    private static func burstPlan(withBurstIdentifier burstIdentifier: String) -> PhotoBurstUploadPlan? {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        let fetch = PHAsset.fetchAssets(withBurstIdentifier: burstIdentifier, options: options)
        var descriptors: [PhotoBurstAssetDescriptor] = []
        descriptors.reserveCapacity(fetch.count)
        fetch.enumerateObjects { member, _, _ in
            descriptors.append(
                PhotoBurstAssetDescriptor(
                    info: assetInfo(for: member, cloudIdentifier: nil),
                    isUserPick: member.burstSelectionTypes.contains(.userPick),
                    representsBurst: member.representsBurst
                ))
        }
        return PhotoBurstUploadPlanner.plan(for: descriptors)
    }

    /// One asset by identifier, series members included. The default fetch hides every photo of a series
    /// except the representative and the user's picks, so a member lookup must include all burst assets.
    static func asset(withLocalIdentifier identifier: String) -> PHAsset? {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        return PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: options).firstObject
    }

    private static func assetInfo(for asset: PHAsset, cloudIdentifier: String?) -> PhotoBackupAssetInfo {
        let resources = PHAssetResource.assetResources(for: asset).map { resource in
            PhotoBackupAssetInfo.Resource(
                role: role(for: resource.type),
                originalFilename: resource.originalFilename,
                mimeType: UTType(resource.uniformTypeIdentifier)?.preferredMIMEType
            )
        }
        let isVideo = asset.mediaType == .video
        return PhotoBackupAssetInfo(
            localIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            durationSeconds: asset.duration,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            isVideo: isVideo,
            resources: resources,
            cloudIdentifier: cloudIdentifier,
            hasAdjustments: asset.hasAdjustments,
            adjustmentTimestamp: asset.adjustmentTimestamp,
            livePlaybackOff: livePlaybackOff(isVideo: isVideo, resources: resources, playbackStyle: asset.playbackStyle)
        )
    }

    /// A Live Photo that Photos presents as a still image: the person turned its Live effect off. Photos then drops
    /// `.photoLive` from the subtypes but still lists the paired video. Loop and Bounce play as a looping video and stay
    /// Live Photos.
    static func livePlaybackOff(
        isVideo: Bool, resources: [PhotoBackupAssetInfo.Resource], playbackStyle: PHAsset.PlaybackStyle
    ) -> Bool {
        !isVideo && playbackStyle == .image && resources.contains { $0.role == .pairedVideo }
    }

    /// Maps a PhotoKit chunk with one cloud-identifier query instead of one query per asset.
    static func infos(for assets: [PHAsset]) -> [PhotoBackupAssetInfo] {
        guard !assets.isEmpty else { return [] }
        let identifiers = assets.map(\.localIdentifier)
        let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(
            forLocalIdentifiers: identifiers
        )
        var plans = BurstPlanCache()
        return assets.map { asset in
            let cloudIdentifier = mappings[asset.localIdentifier]
                .flatMap { try? $0.get().stringValue }
            return info(for: asset, cloudIdentifier: cloudIdentifier, plans: &plans)
        }
    }

    static func role(for type: PHAssetResourceType) -> PhotoBackupAssetInfo.Resource.Role {
        switch type {
        case .photo: return .originalPhoto
        case .alternatePhoto: return .alternatePhoto
        case .fullSizePhoto: return .fullSizePhoto
        case .video: return .originalVideo
        case .audio: return .audio
        case .fullSizeVideo: return .fullSizeVideo
        case .pairedVideo: return .pairedVideo
        case .fullSizePairedVideo: return .fullSizePairedVideo
        case .adjustmentData: return .adjustmentData
        case .adjustmentBasePhoto: return .adjustmentBasePhoto
        case .adjustmentBaseVideo: return .adjustmentBaseVideo
        case .adjustmentBasePairedVideo: return .adjustmentBasePairedVideo
        case .photoProxy: return .photoProxy
        default:
            return .other
        }
    }

    /// The concrete `PHAssetResource` behind a plan item.
    static func resource(
        for role: PhotoBackupAssetInfo.Resource.Role,
        ordinal: Int = 0,
        of asset: PHAsset
    ) -> PHAssetResource? {
        let matches = PHAssetResource.assetResources(for: asset)
            .filter { self.role(for: $0.type) == role }
            .sorted { lhs, rhs in
                if lhs.originalFilename.localizedStandardCompare(rhs.originalFilename) != .orderedSame {
                    return lhs.originalFilename.localizedStandardCompare(rhs.originalFilename) == .orderedAscending
                }
                let left = UTType(lhs.uniformTypeIdentifier)?.preferredMIMEType ?? ""
                let right = UTType(rhs.uniformTypeIdentifier)?.preferredMIMEType ?? ""
                return left < right
            }
        guard ordinal >= 0, ordinal < matches.count else { return nil }
        return matches[ordinal]
    }
}
