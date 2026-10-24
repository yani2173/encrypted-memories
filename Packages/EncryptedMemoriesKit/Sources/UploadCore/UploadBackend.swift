import Foundation
import PhotosCore

// MARK: - Progress

/// Fine-grained progress emitted by an upload backend, mapped to `UploadItemState` by the manager.
public struct UploadProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case preparing  // generating thumbnails, reading attributes
        case hashing  // computing content hash
        case uploading  // streaming encrypted blocks
    }

    public let phase: Phase
    public let fraction: Double  // 0…1, meaningful for `.uploading`

    public init(phase: Phase, fraction: Double = 0) {
        self.phase = phase
        self.fraction = fraction
    }
}

// MARK: - Capabilities

/// What the wired upload backend can do - surfaced to the UI and the `[SDKCapabilities]` log so the
/// app never advertises (e.g.) resumable upload it can't deliver.
public struct UploadBackendCapabilities: Sendable, Equatable {
    public var canUpload: Bool
    public var supportsCancel: Bool
    /// True pause/resume of an in-flight transfer (SDK `UploadOperation`).
    public var supportsPauseResume: Bool
    /// Resume of a partially-uploaded file across an app relaunch. The SDK keeps operation state in
    /// memory only, so this is false: relaunch re-queues incomplete items as retry-from-start.
    public var supportsResumeAcrossRelaunch: Bool

    public init(
        canUpload: Bool,
        supportsCancel: Bool,
        supportsPauseResume: Bool,
        supportsResumeAcrossRelaunch: Bool
    ) {
        self.canUpload = canUpload
        self.supportsCancel = supportsCancel
        self.supportsPauseResume = supportsPauseResume
        self.supportsResumeAcrossRelaunch = supportsResumeAcrossRelaunch
    }

    public static let unavailable = UploadBackendCapabilities(
        canUpload: false, supportsCancel: false, supportsPauseResume: false, supportsResumeAcrossRelaunch: false
    )

    /// The current wired SDK uploader: upload + queue-level cancel work; in-flight pause/resume and
    /// resume-across-relaunch are not. The bridge retains an operation only for its current call so
    /// cancellation can dispose server drafts; it does not persist the operation across launches.
    public static let sdkUploader = UploadBackendCapabilities(
        canUpload: true, supportsCancel: true, supportsPauseResume: false, supportsResumeAcrossRelaunch: false
    )
}

// MARK: - Upload backend (SDK seam)

/// The single seam between `UploadFeature` and the Proton SDK. The app implements this over
/// `EncryptedMemoriesClient` (thumbnail generation, hashing, the storage stream). The feature module
/// never imports the SDK, so the queue/state-machine is testable with a mock.
public protocol PhotoUploading: Sendable {
    var capabilities: UploadBackendCapabilities { get }

    /// Waits until an upload of this network kind may start; see `UploadNetworkAdmission`. Every caller reserves before
    /// it calls `upload` and puts the reservation into `PhotoUploadRequest.networkReservation`.
    func reserveNetwork(allowsExpensiveNetwork: Bool) async throws -> UploadNetworkReservation

    /// Uploads one file to the photo library, returning the new photo's identifier.
    func upload(
        _ request: PhotoUploadRequest,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID

    func cancel(token: UUID) async
    func pause(token: UUID) async throws
    func resume(token: UUID) async throws

    /// Throws `UploadError.accountStorageFull` when the account's remaining storage cannot hold `bytes`. The runner
    /// asks after the duplicate check and before it copies an original for upload, so a file that cannot fit is
    /// neither copied for upload nor sent. An original that lives only in iCloud was already read for its identity.
    func ensureRemoteCapacity(forBytes bytes: Int64, filename: String) async throws
}

public extension PhotoUploading {
    func pause(token: UUID) async throws {}
    func resume(token: UUID) async throws {}
    func ensureRemoteCapacity(forBytes bytes: Int64, filename: String) async throws {}
}

// MARK: - Photo tags (series migration seam, optional)

/// Adds Proton photo tags to an existing photo. Backup uses it only to mark a main photo that an earlier
/// build uploaded without the bursts tag, after its missing series members are related to it. An empty
/// `volumeID` means "the photos volume", as for `PhotoUploadRequest.mainPhotoUID`.
public protocol PhotoTagAdding: Sendable {
    func addTags(_ tags: [Int], to uid: PhotoUID) async throws
}

// MARK: - Album attachment (albums seam, optional)

/// The album side of an upload. Optional: when nil, only library uploads are possible. Implemented in
/// the app by bridging `AlbumCore.AlbumManaging`, so
/// `UploadFeature` and album management stay independently removable.
///
/// `resolveAlbum` runs once per batch *before* uploading, and must throw if the destination can't be
/// honoured (e.g. album creation unsupported) - so the app never silently uploads to the library when
/// the user picked an album.
public protocol AlbumAttaching: Sendable {
    func resolveAlbum(for target: UploadDestination.Target) async throws -> String?
    func addPhoto(_ uid: PhotoUID, to albumID: String) async throws
    func setCover(albumID: String, photo: PhotoUID) async throws
}
