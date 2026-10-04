import CryptoKit
import Foundation
import PhotosCore
import UploadCore

/// PhotoKit-free description of one photo-library asset - the mapper translates `PHAsset` +
/// `PHAssetResource` into this, and every planning decision (what to export, how to fingerprint,
/// what candidate to emit) is pure logic over these values, fully covered by SPM tests.
public struct PhotoBackupAssetInfo: Sendable, Equatable {
    public struct Resource: Sendable, Equatable {
        /// Platform-neutral projection of `PHAssetResourceType`.
        public enum Role: String, Sendable, CaseIterable {
            case originalPhoto
            case alternatePhoto
            case fullSizePhoto
            case originalVideo
            case audio
            case fullSizeVideo
            case pairedVideo
            case fullSizePairedVideo
            case adjustmentData
            case adjustmentBasePhoto
            case adjustmentBaseVideo
            case adjustmentBasePairedVideo
            case photoProxy
            /// Another photo of the same series, carried by the series' main photo. `originalFilename` is
            /// the member's upload filename. Not a `PHAssetResourceType`; see `PhotoBurstUploadPlanner`.
            case burstMember
            /// Marks a series photo whose main photo is another asset. `originalFilename` is that asset's
            /// local identifier. The marked asset uploads only as a member of the main photo's compound.
            case burstMainReference
            case other
        }

        public var role: Role
        public var originalFilename: String
        public var mimeType: String?
        /// Stable ordinal among resources with the same role after deterministic sorting.
        public var ordinal: Int

        public init(role: Role, originalFilename: String, mimeType: String? = nil, ordinal: Int = 0) {
            self.role = role
            self.originalFilename = originalFilename
            self.mimeType = mimeType
            self.ordinal = ordinal
        }
    }

    public var localIdentifier: String
    public var creationDate: Date?
    public var modificationDate: Date?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var durationSeconds: Double
    public var isLivePhoto: Bool
    public var isVideo: Bool
    public var resources: [Resource]
    /// Stable iCloud identity when PhotoKit can provide one. Discovery resolves these in batches;
    /// Core treats it as upload metadata, never as the local lookup key.
    public var cloudIdentifier: String?
    /// Photos reports an edit (`PHAsset.hasAdjustments`), whether or not its rendered file is listed yet.
    public var hasAdjustments: Bool
    /// When the photo was last edited or reverted (`PHAsset.adjustmentTimestamp`); nil for a photo never edited.
    public var adjustmentTimestamp: Date?

    public init(
        localIdentifier: String,
        creationDate: Date?,
        modificationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int,
        durationSeconds: Double,
        isLivePhoto: Bool,
        isVideo: Bool,
        resources: [Resource],
        cloudIdentifier: String? = nil,
        hasAdjustments: Bool = false,
        adjustmentTimestamp: Date? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds
        self.isLivePhoto = isLivePhoto
        self.isVideo = isVideo
        self.resources = resources
        self.cloudIdentifier = cloudIdentifier
        self.hasAdjustments = hasAdjustments
        self.adjustmentTimestamp = adjustmentTimestamp
    }

    public var hasEditEvidence: Bool {
        resources.contains { resource in
            switch resource.role {
            case .adjustmentData, .adjustmentBasePhoto, .adjustmentBaseVideo,
                .adjustmentBasePairedVideo, .fullSizePhoto, .fullSizeVideo,
                .fullSizePairedVideo:
                return true
            default:
                return false
            }
        }
    }
}

/// What Apple Photos knows about an asset beyond its files. The upload carries it as Proton photo tags, so the
/// photo appears in the matching collection. Live Photos, series, and videos get their tags elsewhere.
public struct PhotoBackupAssetTraits: Sendable, Equatable {
    public var isFavorite: Bool
    public var isScreenshot: Bool
    public var isPortrait: Bool
    public var isPanorama: Bool
    /// The uploaded main file is a RAW image. A RAW file that Photos keeps next to a JPEG is a related file.
    public var isRaw: Bool

    public init(
        isFavorite: Bool = false,
        isScreenshot: Bool = false,
        isPortrait: Bool = false,
        isPanorama: Bool = false,
        isRaw: Bool = false
    ) {
        self.isFavorite = isFavorite
        self.isScreenshot = isScreenshot
        self.isPortrait = isPortrait
        self.isPanorama = isPanorama
        self.isRaw = isRaw
    }

    public var protonTags: [Int] {
        var tags: [PhotoTag] = []
        if isFavorite { tags.append(.favorites) }
        if isScreenshot { tags.append(.screenshots) }
        if isPortrait { tags.append(.portraits) }
        if isPanorama { tags.append(.panoramas) }
        if isRaw { tags.append(.raw) }
        return tags.map(\.rawValue)
    }
}

/// What to export for one asset: the current user-visible bytes (edited variants when present,
/// originals otherwise) as primary, plus every other officially exposed PhotoKit resource as a
/// secondary. Bytes are never rendered or converted by us; roles map 1:1 to `PHAssetResource`s.
public struct PhotoBackupExportPlan: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var role: PhotoBackupAssetInfo.Resource.Role
        public var ordinal: Int
        /// The filename the upload carries. Original resources keep their original filenames; edited
        /// renders keep the original basename with an extension that matches the rendered bytes.
        public var uploadFilename: String
        public var mimeType: String?
        public var sourceResource: UploadSourceIdentity.Resource

        public init(
            role: PhotoBackupAssetInfo.Resource.Role,
            ordinal: Int = 0,
            uploadFilename: String,
            mimeType: String?,
            sourceResource: UploadSourceIdentity.Resource
        ) {
            self.role = role
            self.ordinal = ordinal
            self.uploadFilename = uploadFilename
            self.mimeType = mimeType
            self.sourceResource = sourceResource
        }
    }

    public var primary: Item
    /// Every additional PhotoKit resource that must be tied to the primary in Proton Drive.
    public var secondaries: [Item]

    public init(primary: Item, secondaries: [Item] = []) {
        self.primary = primary
        self.secondaries = secondaries
    }
}

/// Pure planning over `PhotoBackupAssetInfo`. No PhotoKit, no I/O.
public enum PhotoBackupAssetPlanner {
    /// Quick successive edits (rotating twice, undoing) upload once: a photo waits this long after its last edit.
    public static let editQuietPeriod: TimeInterval = 5
    /// Photos lists the rendered file of an edit a moment after it reports the edit. The backup waits for it at
    /// most this long after the edit, then plans with the resources that exist; it never renders by itself.
    public static let renderWaitLimit: TimeInterval = 120
    /// While the rendered file is missing, the photo is checked again at this interval.
    public static let renderRecheckInterval: TimeInterval = 15

    /// The moment to check the photo again, or nil when it can be planned now. Planning during an edit
    /// could upload an intermediate state, or the original as if the edit were undone.
    public static func notReadyUntil(for info: PhotoBackupAssetInfo, now: Date) -> Date? {
        // A timestamp ahead of the clock comes from a clock that ran ahead; waiting for it could hold the photo
        // back for as long as the difference, so the photo is ready.
        guard let edited = info.adjustmentTimestamp, edited <= now else { return nil }
        let quietEnd = edited.addingTimeInterval(editQuietPeriod)
        if now < quietEnd { return quietEnd }
        let renderWaitEnd = edited.addingTimeInterval(renderWaitLimit)
        guard lacksRender(info), now < renderWaitEnd else { return nil }
        return min(now.addingTimeInterval(renderRecheckInterval), renderWaitEnd)
    }

    /// The candidate the shared preflight classifies. Nil when the asset exposes no exportable
    /// primary resource (broken/placeholder assets are skipped, never guessed at).
    public static func candidate(for info: PhotoBackupAssetInfo) -> UploadBackupAssetCandidate? {
        guard let plan = exportPlan(for: info) else { return nil }
        let snapshot = UploadBackupAssetSnapshot(
            source: source(for: info),
            revision: metadataRevision(for: info),
            editRevision: editRevision(for: info),
            resourceCount: 1 + plan.secondaries.count,
            externalIdentity: externalIdentity(for: info)
        )
        return UploadBackupAssetCandidate(
            snapshot: snapshot,
            originalFilename: plan.primary.uploadFilename,
            byteCount: nil  // PHAssetResource exposes no official size pre-export on current OSes
        )
    }

    public static func source(for info: PhotoBackupAssetInfo) -> UploadSourceIdentity {
        UploadSourceIdentity(kind: .photoLibraryAsset, identifier: info.localIdentifier, resource: .primary)
    }

    /// Metadata revision: PhotoKit moves `modificationDate` on content AND metadata changes, so
    /// this drifts often - the edit-revision evidence below keeps drift cheap for unedited assets.
    ///
    /// A series main photo mixes its structural fingerprint in: PhotoKit leaves the main photo's dates alone
    /// when members appear or change, and a main photo that an earlier build backed up as a plain photo must
    /// re-open so that its missing members upload.
    public static func metadataRevision(for info: PhotoBackupAssetInfo) -> UploadBackupRevision {
        let date = UploadBackupRevision(date: info.modificationDate ?? info.creationDate ?? .distantPast)
        // One step earlier than the revision with the rendered file: revisions of one photo order by time.
        let dateRevision = lacksRender(info) ? UploadBackupRevision(rawValue: date.rawValue - 1) : date
        guard info.resources.contains(where: { $0.role == .burstMember }) else { return dateRevision }
        return revision(hashing: "series#\(dateRevision.rawValue)#\(fingerprintRevision(for: info).rawValue)")
    }

    /// An edit whose rendered file Photos does not list. The backup of such a photo holds the original, so its
    /// revision differs from the one with the rendered file: the photo re-opens when the rendered file appears,
    /// even when Photos leaves the dates alone.
    static func lacksRender(_ info: PhotoBackupAssetInfo) -> Bool {
        info.hasAdjustments && !listsRender(info)
    }

    /// Whether Photos lists the rendered file of an edit.
    static func listsRender(_ info: PhotoBackupAssetInfo) -> Bool {
        let render: PhotoBackupAssetInfo.Resource.Role = info.isVideo ? .fullSizeVideo : .fullSizePhoto
        return info.resources.contains { $0.role == render }
    }

    /// The source under which the plan keeps the original as a related file of the rendered main file. Nil when the
    /// plan has no such related file.
    static func originalSecondarySource(for info: PhotoBackupAssetInfo) -> UploadSourceIdentity? {
        let role: PhotoBackupAssetInfo.Resource.Role = info.isVideo ? .originalVideo : .originalPhoto
        guard let item = exportPlan(for: info)?.secondaries.first(where: { $0.role == role && $0.ordinal == 0 }) else {
            return nil
        }
        return UploadSourceIdentity(
            kind: .photoLibraryAsset, identifier: info.localIdentifier, resource: item.sourceResource)
    }

    private static func externalIdentity(for info: PhotoBackupAssetInfo) -> UploadBackupExternalIdentity? {
        guard let identifier = info.cloudIdentifier, !identifier.isEmpty,
            let revisionDate = info.modificationDate ?? info.creationDate
        else {
            return nil
        }
        return UploadBackupExternalIdentity(identifier: identifier, modificationDate: revisionDate)
    }

    /// Edit evidence uses PhotoKit's resource structure. Stable structure produces a fingerprint;
    /// edited assets use `.unavailable` and require hash verification because revisions are not distinct.
    public static func editRevision(for info: PhotoBackupAssetInfo) -> UploadBackupEditRevision {
        guard !info.hasEditEvidence else { return .unavailable }
        return .revision(fingerprintRevision(for: info))
    }

    static func fingerprintRevision(for info: PhotoBackupAssetInfo) -> UploadBackupRevision {
        let parts = info.resources
            .map { "\($0.role.rawValue):\($0.ordinal):\($0.originalFilename):\($0.mimeType ?? "")" }
            .sorted()
            .joined(separator: "|")
        let material =
            "\(parts)#\(info.pixelWidth)x\(info.pixelHeight)#\(Int(info.durationSeconds * 1000))#live=\(info.isLivePhoto)"
        return revision(hashing: material)
    }

    private static func revision(hashing material: String) -> UploadBackupRevision {
        let digest = SHA256.hash(data: Data(material.utf8))
        var raw: Int64 = 0
        for byte in digest.prefix(8) { raw = (raw << 8) | Int64(byte) }
        // Positive, and never colliding with the µs-quantized date space of real timestamps is
        // not required - the preflight keys records by exact value either way.
        return UploadBackupRevision(rawValue: raw & 0x7FFF_FFFF_FFFF_FFFF)
    }

    /// Chooses the complete resource set:
    /// - primary = current user-visible photo/video resource when present, else the original;
    /// - secondaries = all other official PhotoKit resources, including RAW alternates, originals,
    ///   Live Photo paired videos, adjustment data/base resources, audio, proxies, and unknown
    ///   future resources surfaced by PhotoKit.
    ///
    /// For an edited render we keep the user's original basename but use the render's extension, so
    /// `IMG_1234.HEIC` + `FullSizeRender.jpg` becomes primary `IMG_1234.jpg` and the untouched
    /// `IMG_1234.HEIC` is retained as a secondary. That avoids lying about bytes vs extension while
    /// preserving the recognizable camera filename.
    ///
    /// A series main photo also lists every other photo of the series as a `.burstMember` secondary. A series
    /// photo that references another main photo has no plan of its own.
    public static func exportPlan(for info: PhotoBackupAssetInfo) -> PhotoBackupExportPlan? {
        guard !info.resources.contains(where: { $0.role == .burstMainReference }) else { return nil }
        let resources = normalizedResources(info.resources)
        func resource(_ role: PhotoBackupAssetInfo.Resource.Role) -> PhotoBackupAssetInfo.Resource? {
            resources.first { $0.role == role }
        }

        let original = info.isVideo ? resource(.originalVideo) : resource(.originalPhoto)
        let edited = info.isVideo ? resource(.fullSizeVideo) : resource(.fullSizePhoto)
        guard let exported = edited ?? original else { return nil }
        let uploadName = primaryUploadFilename(exported: exported, original: original)
        let primary = PhotoBackupExportPlan.Item(
            role: exported.role,
            ordinal: exported.ordinal,
            uploadFilename: uploadName,
            mimeType: exported.mimeType ?? original?.mimeType,
            sourceResource: .primary
        )

        var seenNames: Set<String> = [primary.uploadFilename.lowercased()]
        var secondaries: [PhotoBackupExportPlan.Item] = []
        for resource in resources where !isSameResource(resource, exported) {
            let filename = uniqueFilename(
                preferred: secondaryUploadFilename(for: resource, primaryOriginal: original ?? exported),
                role: resource.role,
                seen: &seenNames
            )
            secondaries.append(
                PhotoBackupExportPlan.Item(
                    role: resource.role,
                    ordinal: resource.ordinal,
                    uploadFilename: filename,
                    mimeType: resource.mimeType,
                    sourceResource: sourceResource(for: resource)
                ))
        }
        return PhotoBackupExportPlan(primary: primary, secondaries: secondaries)
    }

    private static func normalizedResources(
        _ resources: [PhotoBackupAssetInfo.Resource]
    ) -> [PhotoBackupAssetInfo.Resource] {
        var counters: [PhotoBackupAssetInfo.Resource.Role: Int] = [:]
        return
            resources
            .sorted { lhs, rhs in
                if rolePriority(lhs.role) != rolePriority(rhs.role) {
                    return rolePriority(lhs.role) < rolePriority(rhs.role)
                }
                if lhs.originalFilename.localizedStandardCompare(rhs.originalFilename) != .orderedSame {
                    return lhs.originalFilename.localizedStandardCompare(rhs.originalFilename) == .orderedAscending
                }
                return (lhs.mimeType ?? "") < (rhs.mimeType ?? "")
            }
            .map { resource in
                let ordinal = counters[resource.role, default: 0]
                counters[resource.role] = ordinal + 1
                var copy = resource
                copy.ordinal = ordinal
                return copy
            }
    }

    private static func isSameResource(
        _ lhs: PhotoBackupAssetInfo.Resource,
        _ rhs: PhotoBackupAssetInfo.Resource
    ) -> Bool {
        lhs.role == rhs.role
            && lhs.ordinal == rhs.ordinal
            && lhs.originalFilename == rhs.originalFilename
            && lhs.mimeType == rhs.mimeType
    }

    private static func sourceResource(for resource: PhotoBackupAssetInfo.Resource) -> UploadSourceIdentity.Resource {
        if resource.role == .pairedVideo && resource.ordinal == 0 {
            return .livePairedVideo
        }
        if resource.role == .burstMember {
            return .burstMember(ordinal: resource.ordinal)
        }
        return .photoKit(role: resource.role.rawValue, ordinal: resource.ordinal)
    }

    private static func primaryUploadFilename(
        exported: PhotoBackupAssetInfo.Resource,
        original: PhotoBackupAssetInfo.Resource?
    ) -> String {
        guard let original, exported.role != original.role else {
            return nonEmptyFilename(exported.originalFilename, fallback: exported.role.rawValue)
        }
        let base = deletingExtension(nonEmptyFilename(original.originalFilename, fallback: "Photo"))
        let ext =
            pathExtension(exported.originalFilename)
            ?? preferredExtension(for: exported.mimeType)
            ?? pathExtension(original.originalFilename)
            ?? "dat"
        return "\(base).\(ext)"
    }

    private static func secondaryUploadFilename(
        for resource: PhotoBackupAssetInfo.Resource,
        primaryOriginal: PhotoBackupAssetInfo.Resource
    ) -> String {
        let fallbackBase = deletingExtension(nonEmptyFilename(primaryOriginal.originalFilename, fallback: "Photo"))
        let fallbackExt = preferredExtension(for: resource.mimeType) ?? roleExtension(resource.role)
        let fallback = "\(fallbackBase).\(resource.role.rawValue).\(fallbackExt)"
        return nonEmptyFilename(resource.originalFilename, fallback: fallback)
    }

    private static func uniqueFilename(
        preferred: String,
        role: PhotoBackupAssetInfo.Resource.Role,
        seen: inout Set<String>
    ) -> String {
        let cleaned = nonEmptyFilename(preferred, fallback: "\(role.rawValue).dat")
        if seen.insert(cleaned.lowercased()).inserted { return cleaned }
        let base = deletingExtension(cleaned)
        let ext = pathExtension(cleaned) ?? roleExtension(role)
        var suffix = 1
        while true {
            let candidate = "\(base)-\(role.rawValue)-\(suffix).\(ext)"
            if seen.insert(candidate.lowercased()).inserted { return candidate }
            suffix += 1
        }
    }

    private static func rolePriority(_ role: PhotoBackupAssetInfo.Resource.Role) -> Int {
        switch role {
        case .fullSizePhoto: 0
        case .originalPhoto: 1
        case .alternatePhoto: 2
        case .photoProxy: 3
        case .fullSizeVideo: 4
        case .originalVideo: 5
        case .fullSizePairedVideo: 6
        case .pairedVideo: 7
        case .audio: 8
        case .adjustmentData: 9
        case .adjustmentBasePhoto: 10
        case .adjustmentBaseVideo: 11
        case .adjustmentBasePairedVideo: 12
        case .burstMember: 13
        case .burstMainReference: 14
        case .other: 100
        }
    }

    private static func nonEmptyFilename(_ filename: String, fallback: String) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func deletingExtension(_ filename: String) -> String {
        let ns = filename as NSString
        let base = ns.deletingPathExtension
        return base.isEmpty ? filename : base
    }

    private static func pathExtension(_ filename: String) -> String? {
        let ext = (filename as NSString).pathExtension
        return ext.isEmpty ? nil : ext.lowercased()
    }

    private static func preferredExtension(for mimeType: String?) -> String? {
        switch mimeType?.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/tiff": return "tif"
        case "image/x-adobe-dng", "image/dng", "image/adobe-dng": return "dng"
        case "video/quicktime": return "mov"
        case "video/mp4": return "mp4"
        case "audio/mpeg": return "mp3"
        case "application/json": return "json"
        case "application/xml", "text/xml": return "xml"
        default: return nil
        }
    }

    private static func roleExtension(_ role: PhotoBackupAssetInfo.Resource.Role) -> String {
        switch role {
        case .originalPhoto, .alternatePhoto, .fullSizePhoto, .adjustmentBasePhoto, .photoProxy, .burstMember:
            return "img"
        case .originalVideo, .fullSizeVideo, .pairedVideo, .fullSizePairedVideo, .adjustmentBaseVideo,
            .adjustmentBasePairedVideo:
            return "mov"
        case .audio:
            return "audio"
        case .adjustmentData, .burstMainReference, .other:
            return "dat"
        }
    }
}
