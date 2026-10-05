import Foundation

// MARK: - Identifiers

/// SDK-agnostic photo identifier (mirrors the SDK's volume/node pair).
public struct PhotoUID: Hashable, Sendable, Codable {
    public let volumeID: String
    public let nodeID: String
    public init(volumeID: String, nodeID: String) {
        self.volumeID = volumeID
        self.nodeID = nodeID
    }
}

// MARK: - Models

/// One item on the photo timeline. Kept intentionally lightweight - heavy data
/// (full image/video) is loaded lazily through the providers below.
public struct PhotoItem: Identifiable, Hashable, Sendable, Codable {
    public let uid: PhotoUID
    public let captureTime: Date
    public let mediaType: String  // e.g. "image/jpeg", "video/quicktime"
    public let isLivePhoto: Bool
    /// For a Live Photo, the node ID (same volume) of the paired video file.
    public let relatedVideoID: String?
    public let durationSeconds: Double?  // for videos
    /// Proton's server-side smart tags when the current backend path exposes them. SDK timeline enumeration
    /// can omit these; callers must treat this as enrichment, not the source of all truth.
    public let tags: Set<PhotoTag>
    /// Link IDs of every photo in the same burst/series, in presentation order. Empty means either
    /// "not a burst" or "the backend path has not enriched this item yet"; callers that need the full
    /// group should ask `BurstGroupProvider` on demand.
    public let burstMemberIDs: [String]

    public var id: PhotoUID { uid }

    public var isVideo: Bool { mediaType.hasPrefix("video/") }
    public var isBurstCandidate: Bool { tags.contains(.bursts) || burstMemberIDs.count > 1 }

    /// The paired video's identifier, for Live Photo playback.
    public var relatedVideoUID: PhotoUID? {
        relatedVideoID.map { PhotoUID(volumeID: uid.volumeID, nodeID: $0) }
    }

    /// Stable UIDs for all known members of this burst/series.
    public var burstMemberUIDs: [PhotoUID] {
        burstMemberIDs.map { PhotoUID(volumeID: uid.volumeID, nodeID: $0) }
    }

    public init(
        uid: PhotoUID,
        captureTime: Date,
        mediaType: String,
        isLivePhoto: Bool = false,
        relatedVideoID: String? = nil,
        durationSeconds: Double? = nil,
        tags: Set<PhotoTag> = [],
        burstMemberIDs: [String] = []
    ) {
        self.uid = uid
        self.captureTime = captureTime
        self.mediaType = mediaType
        self.isLivePhoto = isLivePhoto
        self.relatedVideoID = relatedVideoID
        self.durationSeconds = durationSeconds
        self.tags = tags
        self.burstMemberIDs = burstMemberIDs
    }

    private enum CodingKeys: String, CodingKey {
        case uid, captureTime, mediaType, isLivePhoto, relatedVideoID, durationSeconds, tags, burstMemberIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(PhotoUID.self, forKey: .uid)
        captureTime = try container.decode(Date.self, forKey: .captureTime)
        mediaType = try container.decode(String.self, forKey: .mediaType)
        isLivePhoto = try container.decodeIfPresent(Bool.self, forKey: .isLivePhoto) ?? false
        relatedVideoID = try container.decodeIfPresent(String.self, forKey: .relatedVideoID)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        tags = try container.decodeIfPresent(Set<PhotoTag>.self, forKey: .tags) ?? []
        burstMemberIDs = try container.decodeIfPresent([String].self, forKey: .burstMemberIDs) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uid, forKey: .uid)
        try container.encode(captureTime, forKey: .captureTime)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encode(isLivePhoto, forKey: .isLivePhoto)
        try container.encodeIfPresent(relatedVideoID, forKey: .relatedVideoID)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try container.encode(tags.sorted { $0.rawValue < $1.rawValue }, forKey: .tags)
        try container.encode(burstMemberIDs, forKey: .burstMemberIDs)
    }
}

extension PhotoItem {
    /// The length of a video as the library shows it, for example "0:42" or "1:01:01". Nil for a photo and for a
    /// video whose length is unknown.
    public var durationText: String? { isVideo ? Self.durationText(for: durationSeconds) : nil }

    /// A video length in seconds as the library shows it. Nil for a missing, invalid, or empty length.
    public static func durationText(for seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0, seconds < Double(Int.max) else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(remainder))"
        }
        return "\(minutes):\(twoDigits(remainder))"
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

/// A date-grouped run of photos, like the macOS Photos app day/month headers.
public struct TimelineSection: Identifiable, Sendable, Codable {
    public let id: String  // stable key, e.g. "2026-06-13"
    public let date: Date
    public let title: String
    public var items: [PhotoItem]

    public init(id: String, date: Date, title: String, items: [PhotoItem]) {
        self.id = id
        self.date = date
        self.title = title
        self.items = items
    }
}

// MARK: - Provider protocols (implemented by the SDK glue in the app target)

/// A persisted inventory and the opaque server revision captured atomically with it. Keeping the pair in one
/// value prevents a concurrent refresh from pairing older rows with a newer token and falsely validating them.
public struct CachedTimelineSnapshot: Sendable {
    public let sections: [TimelineSection]
    public let validationToken: String?

    public init(sections: [TimelineSection], validationToken: String?) {
        self.sections = sections
        self.validationToken = validationToken
    }
}

/// One authoritative timeline enumeration and the stable server revision that bracketed it. Returning both
/// values together prevents a reentrant backend refresh from pairing older sections with a newer token between
/// two actor calls.
public struct TimelineLoadSnapshot: Sendable {
    public let sections: [TimelineSection]
    public let validationToken: String?

    public init(sections: [TimelineSection], validationToken: String?) {
        self.sections = sections
        self.validationToken = validationToken
    }
}

/// Marker for an authoritative timeline load that is valid but has not yet converged with a completed local
/// upload. Callers may retry these failures with a bounded schedule; other errors remain terminal.
public protocol TimelineInventoryConvergenceError: Error, Sendable {}

/// Whether the library can show a remote link: its state and, for a related file such as the original of an edit or
/// a Live Photo video, its main photo. A related file stays active on the server when its main photo moves to the
/// trash, so only the main photo's state tells whether the file still belongs to a photo in the library.
public struct RemoteLinkVisibility: Equatable, Sendable {
    public var isActive: Bool
    /// Nil for a main photo.
    public var mainPhotoLinkID: String?
    /// The server time of the move to the trash, in seconds. Nil for a link that is not in the trash.
    public var trashTime: Int64?

    public init(isActive: Bool, mainPhotoLinkID: String?, trashTime: Int64? = nil) {
        self.isActive = isActive
        self.mainPhotoLinkID = mainPhotoLinkID
        self.trashTime = trashTime
    }
}

/// Source of timeline metadata.
public protocol PhotosRepository: Sendable {
    func loadTimeline() async throws -> [TimelineSection]
    /// Loads one authoritative inventory and its paired server revision as a single result. Repositories that
    /// cannot expose a revision may use the default nil token; cache validation will then fail closed.
    func loadTimelineSnapshot() async throws -> TimelineLoadSnapshot
    /// Last-known timeline persisted to disk, for instant startup (nil if none). `loadTimeline()`
    /// then refreshes in the background - stale-while-revalidate, so there's no spinner on relaunch.
    func cachedTimeline() async -> [TimelineSection]?
    /// Reads the cached timeline and its paired validation revision as one snapshot. Implementations that
    /// cannot provide an atomic pair should return a nil token so validation fails closed.
    func cachedTimelineSnapshot() async -> CachedTimelineSnapshot?
    /// Opaque server revision captured atomically with the cached timeline. A caller may present the
    /// cached frame as authoritative only after this equals the provider's current change token.
    func cachedTimelineValidationToken() async -> String?
}

public extension PhotosRepository {
    func loadTimelineSnapshot() async throws -> TimelineLoadSnapshot {
        TimelineLoadSnapshot(sections: try await loadTimeline(), validationToken: nil)
    }
    func cachedTimeline() async -> [TimelineSection]? { nil }
    func cachedTimelineSnapshot() async -> CachedTimelineSnapshot? {
        guard let sections = await cachedTimeline() else { return nil }
        return CachedTimelineSnapshot(sections: sections, validationToken: nil)
    }
    func cachedTimelineValidationToken() async -> String? { nil }
}

/// Cheap, opaque server-side library revision used to notice changes made by another device.
/// Implementations must not enumerate or decrypt the timeline to produce this token.
public protocol LibraryChangeTokenProvider: Sendable {
    func libraryChangeToken() async throws -> String
    /// Same opaque token, requested on the user-visible launch path. Backends with a shared request governor
    /// may raise this above speculative/background traffic; providers without priorities use the default.
    func launchValidationToken() async throws -> String
    /// Allows a backend to use scope already present in the cached inventory (for example its volume ID),
    /// avoiding an unrelated root-discovery request on the user-visible launch path.
    func launchValidationToken(for snapshot: CachedTimelineSnapshot) async throws -> String
}

/// Marker for a change-token failure that cannot recover by polling the same remote scope again.
/// The shared monitor stops until normal account or backend lifecycle code installs a new provider.
public protocol LibraryChangeTerminalError: Error, Sendable {}

public extension LibraryChangeTokenProvider {
    func launchValidationToken() async throws -> String {
        try await libraryChangeToken()
    }

    func launchValidationToken(for snapshot: CachedTimelineSnapshot) async throws -> String {
        try await launchValidationToken()
    }
}

/// Loads thumbnail image bytes for a photo (small grid preview).
public protocol ThumbnailProvider: Sendable {
    func thumbnail(for uid: PhotoUID) async throws -> Data
}

/// How one `loadThumbnails` batch disposed of every uid that did not stream back through
/// `onLoaded`. The feed uses this to classify (and account for) undelivered items instead of
/// collapsing every failure into an unexplained "0/N".
public struct ThumbnailBatchLoadResult: Sendable, Equatable {
    /// The whole call failed (transport/session/SDK error) before or while streaming. Undelivered
    /// items in the batch failed for this reason.
    public let batchError: String?
    /// Failures the backend reported per item (uid to short reason), such as "no thumbnail" or a
    /// decrypt error. These are authoritative answers, not transport problems.
    public let itemErrors: [PhotoUID: String]
    /// Items whose bytes arrived after the caller's read authorization for them changed. They were withheld, not
    /// refused: a later request may deliver them.
    public let withheldUIDs: Set<PhotoUID>

    public init(
        batchError: String? = nil,
        itemErrors: [PhotoUID: String] = [:],
        withheldUIDs: Set<PhotoUID> = []
    ) {
        self.batchError = batchError
        self.itemErrors = itemErrors
        self.withheldUIDs = withheldUIDs
    }

    /// The loader finished normally and reported no failures (items it didn't deliver are simply unknown).
    public static let delivered = ThumbnailBatchLoadResult()
}

/// Bulk thumbnail loading - streams results as the SDK decrypts/downloads them, so the whole
/// library can be filled in the background as fast as the connection allows. Returns a per-batch
/// disposition so callers can explain (and stop retrying) items the backend refused.
public protocol ThumbnailBatchLoader: Sendable {
    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult
}

/// Optional priority-aware refinement used by shared feed scheduling. Loaders that do not need
/// transport prioritization keep implementing `ThumbnailBatchLoader` unchanged.
public protocol PriorityThumbnailBatchLoader: ThumbnailBatchLoader {
    func loadThumbnails(
        for uids: [PhotoUID],
        priority: ThumbnailPriority,
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult
}

/// Loads full-resolution original bytes without creating an app-owned plaintext cache file.
public protocol FullMediaProvider: Sendable {
    /// Larger preview image bytes (shown immediately in the viewer before the original arrives).
    func preview(for uid: PhotoUID) async throws -> Data
    /// Decrypts the original into RAM for viewer/cache consumers, reporting progress (0…1). Export paths must use
    /// `OriginalFileProvider` so a large original is never materialized as one `Data` value.
    func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data
}

/// Streams bounded decrypted chunks of an original to viewer decoders. Viewer paths must prefer this contract
/// over `FullMediaProvider.originalData`, because a full plaintext `Data` allocation defeats bounded decoding.
public protocol OriginalByteStreamProvider: Sendable {
    func streamOriginalBytes(
        for uid: PhotoUID,
        onChunk: @escaping @Sendable (Data) async throws -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws
}

/// Streams a decrypted original directly to a caller-selected file. Large exports must use this contract rather
/// than materializing `Data`; the backend remains responsible for E2EE decryption, retries and integrity checks.
public protocol OriginalFileProvider: Sendable {
    func writeOriginal(
        for uid: PhotoUID,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws
}

public extension OriginalFileProvider {
    func writeOriginal(for uid: PhotoUID, to destination: URL) async throws {
        try await writeOriginal(for: uid, to: destination, onProgress: { _ in })
    }
}

public extension FullMediaProvider {
    func originalData(for uid: PhotoUID) async throws -> Data {
        try await originalData(for: uid, onProgress: { _ in })
    }
}

/// Optional metadata provider for Proton burst/series groups. The viewer calls this lazily only when
/// an item is tagged/enriched as a burst candidate, so the main timeline path stays fast and SDK-agnostic.
public protocol BurstGroupProvider: Sendable {
    func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem]
}
