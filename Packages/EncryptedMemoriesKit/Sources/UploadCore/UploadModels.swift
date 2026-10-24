import Foundation
import PhotosCore

// MARK: - Identifiers

/// Stable identity of one item in the upload queue.
public typealias UploadQueueItemID = UUID

// MARK: - Destination

/// Where a batch of uploads should land. Photos always upload to the Proton photo library first
/// (that's all the SDK supports); album membership is applied afterwards via `AlbumAttaching`.
public struct UploadDestination: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        /// Upload to the photo library only - no album.
        case library
        /// Add to an existing album after upload.
        case existingAlbum(id: String, title: String)
        /// Create the named album, then add uploaded photos to it.
        case newAlbum(name: String)
    }

    /// How to pick the album cover once the batch completes.
    public enum Cover: Sendable, Equatable {
        case unchanged
        case firstUploaded
        case specific(PhotoUID)
    }

    public var target: Target
    public var cover: Cover

    public init(target: Target, cover: Cover = .unchanged) {
        self.target = target
        self.cover = cover
    }

    public static let library = UploadDestination(target: .library)

    /// True when the destination involves an album (and therefore needs `AlbumAttaching` wired).
    public var usesAlbum: Bool {
        if case .library = target { return false }
        return true
    }

    /// Human-readable one-line summary for the destination UI.
    public var summary: String {
        switch target {
        case .library: return L10n.string("upload.summary_library")
        case .existingAlbum(_, let title): return L10n.string("upload.summary_existing_album \(title)")
        case .newAlbum(let name): return L10n.string("upload.summary_new_album \(name)")
        }
    }
}

// MARK: - Item state machine

/// Why an upload queue item finished without uploading new bytes.
public enum UploadSkipReason: Sendable, Equatable {
    /// The active Proton library already contains the same photo.
    case activeDuplicate
    /// The local manifest already proved this exact resource is backed up.
    case knownFromManifest
    /// The primary photo is already present; no manual upload work remains.
    case primaryAlreadyPresent
    /// Proton reports the same photo in trash. Respect the user's deletion instead of restoring it.
    case trashedDuplicate
    /// Proton reports the same photo as deleted remotely. Respect the deletion instead of restoring it.
    case deletedRemotely

    public var countsAsBackedUp: Bool {
        switch self {
        case .activeDuplicate, .knownFromManifest, .primaryAlreadyPresent:
            return true
        case .trashedDuplicate, .deletedRemotely:
            return false
        }
    }

    public var label: String {
        switch self {
        case .activeDuplicate, .knownFromManifest, .primaryAlreadyPresent:
            return L10n.string("upload.state_skipped_duplicate")
        case .trashedDuplicate:
            return L10n.string("upload.state_skipped_trashed")
        case .deletedRemotely:
            return L10n.string("upload.state_skipped_deleted")
        }
    }
}

/// The lifecycle of a single queued upload. Transitions are enforced by `UploadManager`.
public enum UploadItemState: Sendable, Equatable {
    case queued
    case preparing  // building thumbnails / reading attributes
    case hashing  // computing the content hash + checking the server for duplicates
    case uploading(progress: Double)
    case finalizing  // upload done, applying album membership
    case completed
    /// Nothing was uploaded because the dedupe preflight resolved the item without new bytes.
    case skipped(UploadSkipReason)
    case failed(message: String)
    case cancelled
    case paused

    public var isTerminal: Bool {
        switch self {
        case .completed, .skipped, .failed, .cancelled: return true
        default: return false
        }
    }

    public var isActive: Bool {
        switch self {
        case .preparing, .hashing, .uploading, .finalizing: return true
        default: return false
        }
    }

    /// Short label for the queue UI.
    public var label: String {
        switch self {
        case .queued: return L10n.string("upload.state_queued")
        case .preparing: return L10n.string("upload.state_preparing")
        case .hashing: return L10n.string("upload.state_hashing")
        case .uploading(let p): return L10n.string("upload.state_uploading \(Int(p * 100))")
        case .finalizing: return L10n.string("upload.state_finalizing")
        case .completed: return L10n.string("upload.state_completed")
        case .skipped(let reason): return reason.label
        case .failed(let message): return L10n.string("upload.state_failed \(message)")
        case .cancelled: return L10n.string("upload.state_cancelled")
        case .paused: return L10n.string("upload.state_paused")
        }
    }
}

// MARK: - Queue item snapshot

/// An immutable snapshot of a queue item, handed to the UI. `UploadManager` owns the mutable truth.
public struct UploadItem: Identifiable, Sendable, Equatable {
    public let id: UploadQueueItemID
    /// Enqueue order - preserved across snapshots so the list never reshuffles.
    public let ordinal: Int
    public let fileURL: URL
    public let displayName: String
    public let mediaType: String
    public let byteCount: Int64
    public var state: UploadItemState
    /// The uploaded photo's identifier once the library upload succeeds (set before album add).
    public var uploadedUID: PhotoUID?
    /// Set when the file uploaded to the library but a later step (album add / cover) failed - the
    /// photo is not lost. Retry only the album step to recover from the failure.
    public var partialSuccess: Bool

    public init(
        id: UploadQueueItemID,
        ordinal: Int,
        fileURL: URL,
        displayName: String,
        mediaType: String,
        byteCount: Int64,
        state: UploadItemState = .queued,
        uploadedUID: PhotoUID? = nil,
        partialSuccess: Bool = false
    ) {
        self.id = id
        self.ordinal = ordinal
        self.fileURL = fileURL
        self.displayName = displayName
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.state = state
        self.uploadedUID = uploadedUID
        self.partialSuccess = partialSuccess
    }
}

// MARK: - Completion event

/// Emitted as soon as the backend reports a successfully-created library node. Album finalization may
/// still run afterwards, but the asset is safe to look for in the main timeline at this point.
public struct UploadCompletedEvent: Identifiable, Sendable, Equatable {
    public let id: UploadQueueItemID
    public let uploadedUID: PhotoUID
    public let displayName: String
    public let destination: UploadDestination
    public let resolvedAlbumID: String?
    public let completedAt: Date

    public init(
        id: UploadQueueItemID,
        uploadedUID: PhotoUID,
        displayName: String,
        destination: UploadDestination,
        resolvedAlbumID: String?,
        completedAt: Date
    ) {
        self.id = id
        self.uploadedUID = uploadedUID
        self.displayName = displayName
        self.destination = destination
        self.resolvedAlbumID = resolvedAlbumID
        self.completedAt = completedAt
    }
}

// MARK: - Aggregate counts

/// Roll-up of the queue, surfaced to the UI (progress + summary text).
public struct UploadQueueStats: Sendable, Equatable {
    public var queued = 0
    public var active = 0
    public var completed = 0
    /// Items resolved as already-in-library duplicates - done without uploading bytes.
    public var skippedDuplicates = 0
    /// Items skipped because Proton says the matching remote item was deleted or trashed.
    public var skippedRemoteDeletions = 0
    public var failed = 0
    public var cancelled = 0
    public var paused = 0
    public var concurrency = 0
    /// Durable upload state could not be opened. The queue must not present this as an empty history.
    public var persistenceUnavailable = false

    public init() {}

    public var total: Int {
        queued + active + completed + skippedDuplicates + skippedRemoteDeletions + failed + cancelled + paused
    }

    public var totalProgress: Double {
        guard total > 0 else { return 0 }
        return Double(completed + skippedDuplicates + skippedRemoteDeletions) / Double(total)
    }

    public var summaryText: String {
        // Skipped duplicates count as done - the user's photo is in the library either way.
        L10n.string("upload.queue_stats \(completed + skippedDuplicates) \(active) \(failed)")
    }
}

/// User-facing aggregate of the pre-upload duplicate check. The UI deliberately presents this
/// as "checking before upload" rather than "hashing", because most of the time it means the app is
/// proving an item is already backed up and will not upload bytes again.
public struct UploadPreparationStatus: Sendable, Equatable {
    public var total = 0
    public var waiting = 0
    public var checking = 0
    public var checked = 0
    public var skippedDuplicates = 0
    public var skippedRemoteDeletions = 0
    public var failed = 0
    public var cancelled = 0
    public var paused = 0

    public init() {}

    public init(items: [UploadItem]) {
        for item in items {
            total += 1
            switch item.state {
            case .queued, .preparing:
                waiting += 1
            case .hashing:
                checking += 1
            case .uploading, .finalizing, .completed:
                checked += 1
            case .skipped(let reason):
                checked += 1
                if reason.countsAsBackedUp {
                    skippedDuplicates += 1
                } else {
                    skippedRemoteDeletions += 1
                }
            case .failed:
                failed += 1
            case .cancelled:
                cancelled += 1
            case .paused:
                paused += 1
            }
        }
    }

    public var hasItems: Bool { total > 0 }

    public var isRunning: Bool {
        waiting > 0 || checking > 0
    }

    public var resolved: Int {
        max(0, total - waiting - checking - paused)
    }

    public var progressFraction: Double {
        guard total > 0 else { return 0 }
        return Double(resolved) / Double(total)
    }

    public var needsAttention: Int {
        failed + cancelled + paused
    }
}

// MARK: - Queue presentation

public enum UploadQueueRowAction: Sendable, Hashable {
    case cancel
    case pause
    case resume
    case retry
}

public enum UploadQueuePresentation {
    public static func rowActions(
        for item: UploadItem, capabilities: UploadBackendCapabilities
    ) -> [UploadQueueRowAction] {
        switch item.state {
        case .failed, .cancelled:
            return [.retry]
        case .queued, .preparing, .hashing, .uploading:
            return capabilities.supportsPauseResume ? [.pause, .cancel] : [.cancel]
        case .paused:
            return [.resume]
        case .completed, .skipped, .finalizing:
            return []
        }
    }

    public static func canClearFinished(_ stats: UploadQueueStats) -> Bool {
        stats.completed + stats.skippedDuplicates + stats.skippedRemoteDeletions + stats.failed + stats.cancelled > 0
    }
}

// MARK: - Upload request (per file, library-only)

/// One Proton photo extended-attribute fragment. `name` is the XAttr section name
/// (for example `Media` or `iOS.photos`); `utf8JsonValue` is the UTF-8 JSON payload
/// expected by the Proton SDK.
public struct PhotoUploadAdditionalMetadata: Sendable, Equatable {
    public let name: String
    public let utf8JsonValue: Data

    public init(name: String, utf8JsonValue: Data) {
        self.name = name
        self.utf8JsonValue = utf8JsonValue
    }
}

/// Proton photo XAttr sections. The field names match Proton Drive's encrypted photo metadata
/// schema; adapters supply the values, Core owns the JSON shape.
public enum PhotoUploadMetadataEncoder {
    public struct Location: Codable, Sendable, Equatable {
        public let latitude: Double
        public let longitude: Double

        enum CodingKeys: String, CodingKey {
            case latitude = "Latitude"
            case longitude = "Longitude"
        }

        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    public struct SubjectCoordinates: Codable, Sendable, Equatable {
        public let top: Int
        public let left: Int
        public let bottom: Int
        public let right: Int

        enum CodingKeys: String, CodingKey {
            case top = "Top"
            case left = "Left"
            case bottom = "Bottom"
            case right = "Right"
        }

        public init(top: Int, left: Int, bottom: Int, right: Int) {
            self.top = top
            self.left = left
            self.bottom = bottom
            self.right = right
        }
    }

    public struct Camera: Codable, Sendable, Equatable {
        public let captureTime: String?
        public let device: String?
        public let orientation: Int?
        public let subjectCoordinates: SubjectCoordinates?

        enum CodingKeys: String, CodingKey {
            case captureTime = "CaptureTime"
            case device = "Device"
            case orientation = "Orientation"
            case subjectCoordinates = "SubjectCoordinates"
        }

        public init(
            captureTime: String?,
            device: String? = nil,
            orientation: Int? = nil,
            subjectCoordinates: SubjectCoordinates? = nil
        ) {
            self.captureTime = captureTime
            self.device = device
            self.orientation = orientation
            self.subjectCoordinates = subjectCoordinates
        }
    }

    public struct Media: Codable, Sendable, Equatable {
        public let width: Int?
        public let height: Int?
        public let duration: Double?

        enum CodingKeys: String, CodingKey {
            case width = "Width"
            case height = "Height"
            case duration = "Duration"
        }

        public init(width: Int?, height: Int?, duration: Double?) {
            self.width = width
            self.height = height
            self.duration = duration
        }
    }

    public struct IOSPhotos: Codable, Sendable, Equatable {
        public let iCloudID: String?
        public let modificationTime: String?

        enum CodingKeys: String, CodingKey {
            case iCloudID = "ICloudID"
            case modificationTime = "ModificationTime"
        }

        public init(iCloudID: String?, modificationTime: String?) {
            self.iCloudID = iCloudID
            self.modificationTime = modificationTime
        }
    }

    public static func metadata(
        location: Location?,
        camera: Camera,
        media: Media,
        iOSPhotos: IOSPhotos?,
        diagnostics: PhotoDiagnostics = .shared
    ) throws -> [PhotoUploadAdditionalMetadata] {
        let encoder = JSONEncoder()
        var output: [PhotoUploadAdditionalMetadata] = []
        if let location {
            if location.latitude == location.longitude {
                diagnostics.increment("backup.metadata.equalCoordinates")
            }
            output.append(try encode(location, name: "Location", encoder: encoder))
        }
        output.append(try encode(camera, name: "Camera", encoder: encoder))
        output.append(try encode(media, name: "Media", encoder: encoder))
        if let iOSPhotos {
            output.append(try encode(iOSPhotos, name: "iOS.photos", encoder: encoder))
        }
        return output
    }

    private static func encode<T: Encodable>(
        _ value: T,
        name: String,
        encoder: JSONEncoder
    ) throws -> PhotoUploadAdditionalMetadata {
        PhotoUploadAdditionalMetadata(name: name, utf8JsonValue: try encoder.encode(value))
    }
}

/// The library-upload payload for one file. The album/cover orchestration lives in `UploadManager`;
/// this is purely what the SDK needs to push bytes into the photo library.
public struct PhotoUploadRequest: Sendable {
    public let queueItemID: UploadQueueItemID
    public let cancellationToken: UUID
    public let fileURL: URL
    public let name: String
    public let mediaType: String
    public let fileSize: Int64
    public let captureTime: Date
    public let modificationDate: Date
    public let tags: [Int]
    /// Proton-compatible encrypted metadata sections. File bytes still contain their original
    /// embedded EXIF; these sections populate Proton's searchable/decrypted photo XAttrs.
    public let additionalMetadata: [PhotoUploadAdditionalMetadata]
    /// 20-byte SHA-1 of the file, from the dedupe pipeline's hashing phase. The backend forwards
    /// it to the SDK for server-side integrity verification of the streamed bytes.
    public let expectedSHA1: Data?
    /// Uses Proton's explicit server-side draft replacement for a draft proven to belong to this
    /// installation. This is never inferred from a filename collision alone.
    public let overrideExistingDraft: Bool
    /// The compound's primary photo when this request uploads a secondary resource (a Live
    /// Photo's paired video). Nil for primaries. An empty `volumeID` means "the photos volume":
    /// core may only know the primary's link id (duplicate-check rows carry no volume), and the
    /// transport layer resolves the account's single photos volume for it.
    public let mainPhotoUID: PhotoUID?
    /// False when this backup upload must not use cellular data or Personal Hotspot. The transport then lets the
    /// system refuse the bytes on such a network. Uploads that the person starts keep the default.
    public var allowsExpensiveNetwork = true
    /// The upload's place in the account's `UploadNetworkAdmission`. The production uploader refuses a request without
    /// an active reservation of its own admission and of the same network kind.
    public var networkReservation: UploadNetworkReservation?

    public init(
        queueItemID: UploadQueueItemID,
        cancellationToken: UUID,
        fileURL: URL,
        name: String,
        mediaType: String,
        fileSize: Int64,
        captureTime: Date,
        modificationDate: Date,
        tags: [Int],
        additionalMetadata: [PhotoUploadAdditionalMetadata] = [],
        expectedSHA1: Data? = nil,
        overrideExistingDraft: Bool = false,
        mainPhotoUID: PhotoUID? = nil
    ) {
        self.queueItemID = queueItemID
        self.cancellationToken = cancellationToken
        self.fileURL = fileURL
        self.name = name
        self.mediaType = mediaType
        self.fileSize = fileSize
        self.captureTime = captureTime
        self.modificationDate = modificationDate
        self.tags = tags
        self.additionalMetadata = additionalMetadata
        self.expectedSHA1 = expectedSHA1
        self.overrideExistingDraft = overrideExistingDraft
        self.mainPhotoUID = mainPhotoUID
    }

    /// The same request with the dedupe pipeline's findings applied: the Proton-corrected name
    /// (what actually gets hashed remotely) and the integrity digest.
    public func applying(identity: UploadIdentity) -> PhotoUploadRequest {
        copy(
            name: identity.correctedName,
            expectedSHA1: identity.sha1Digest,
            overrideExistingDraft: overrideExistingDraft
        )
    }

    public func replacingExistingDraft(_ shouldReplace: Bool) -> PhotoUploadRequest {
        copy(name: name, expectedSHA1: expectedSHA1, overrideExistingDraft: shouldReplace)
    }

    private func copy(name: String, expectedSHA1: Data?, overrideExistingDraft: Bool) -> PhotoUploadRequest {
        var request = PhotoUploadRequest(
            queueItemID: queueItemID,
            cancellationToken: cancellationToken,
            fileURL: fileURL,
            name: name,
            mediaType: mediaType,
            fileSize: fileSize,
            captureTime: captureTime,
            modificationDate: modificationDate,
            tags: tags,
            additionalMetadata: additionalMetadata,
            expectedSHA1: expectedSHA1,
            overrideExistingDraft: overrideExistingDraft,
            mainPhotoUID: mainPhotoUID
        )
        request.allowsExpensiveNetwork = allowsExpensiveNetwork
        request.networkReservation = networkReservation
        return request
    }
}

// MARK: - Errors

public enum UploadError: LocalizedError, Equatable {
    case unsupportedFile(String)
    case fileMissing(String)
    case permissionDenied(String)
    /// A retryable URL-transport failure preserved across the SDK boundary.
    case transport(code: Int, message: String)
    /// A temporary server-side response (for example HTTP 429 or 5xx). Unlike a permanent backend
    /// rejection, this must not consume an item's finite retry budget and strand valid media.
    case retryableBackend(code: Int?, message: String)
    case backend(String)
    case albumStep(String)
    case cancelled
    /// The platform still prepares the source (the camera still processes a new photo). The runner makes the
    /// row due at `until` without counting an attempt; the finished file usually arrives sooner as a new
    /// revision, which the platform's change notification enqueues.
    case sourceNotReady(String, until: Date)
    /// Photos cannot hand out the file now: it waits for iCloud, an offline library volume, or an interrupted read.
    /// The runner checks the row again after a backoff without an attempt. This says nothing about the Proton
    /// connection, so other uploads keep their concurrency.
    case sourceUnavailable(String)
    /// Photos reports the file as missing. A short iCloud fault can report that too, so the runner checks the row
    /// a few more times, hours apart, before it treats the photo as gone.
    case sourceReportedMissing(String)
    /// The account's remaining Proton storage cannot hold the file. The item waits; freeing space or a larger plan
    /// and Back Up Now take it up again.
    case accountStorageFull(String, requiredBytes: Int64, availableBytes: Int64)

    /// Cancellation can cross the transport boundary without cancelling the enclosing Swift task.
    public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return true }
        guard let uploadError = error as? UploadError else { return false }
        switch uploadError {
        case .cancelled: return true
        case .transport(let code, _): return code == URLError.cancelled.rawValue
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile(let name): L10n.string("error.upload_unsupported_file \(name)")
        case .fileMissing(let name): L10n.string("error.upload_file_missing \(name)")
        case .permissionDenied(let name): L10n.string("error.upload_permission_denied \(name)")
        case .transport(_, let message): message
        case .retryableBackend(_, let message): message
        case .backend(let message): message
        case .albumStep(let message): L10n.string("error.upload_album_step \(message)")
        case .cancelled: L10n.string("error.upload_cancelled")
        case .sourceNotReady(let name, _): L10n.string("error.upload_source_not_ready \(name)")
        case .sourceUnavailable, .sourceReportedMissing: L10n.string("backup.issue_source_unavailable")
        case .accountStorageFull(let name, let required, let available):
            L10n.string(
                "error.upload_account_storage_full \(name) \(L10n.fileSize(required)) \(L10n.fileSize(available))")
        }
    }
}
