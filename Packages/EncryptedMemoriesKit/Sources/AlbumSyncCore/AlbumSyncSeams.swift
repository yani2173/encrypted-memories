import Foundation
import PhotosCore
import UploadCore

/// The platform adapter's view of local albums (PhotoKit on Apple platforms). Permission handling
/// stays in the platform layer: these calls are made only after access is granted.
public protocol AlbumSyncLocalAlbumSource: Sendable {
    /// User-created albums, sorted alphabetically by title (PhotoKit exposes no cross-folder user order).
    func listAlbums() async throws -> [LocalAlbumSummary]
    /// Typed contents of one album in stable display order. May be large; implementations must
    /// enumerate chunked and never load asset bytes. `.present([])` and `.missing` are distinct.
    func albumContents(albumID: String) async throws -> AlbumSyncLocalAlbumContents
    /// Lightweight revalidation used immediately before remote resolution or mutation.
    func albumExists(albumID: String) async throws -> Bool
}

public extension AlbumSyncLocalAlbumSource {
    func albumExists(albumID: String) async throws -> Bool {
        guard case .present = try await albumContents(albumID: albumID) else { return false }
        return true
    }
}

/// Outcome of the "make sure these local assets are backed up" step, aggregated from the backup
/// queue's terminal states.
public struct AlbumSyncBackupReport: Sendable, Equatable {
    public var total = 0
    /// Uploaded now or verified already backed up.
    public var backedUp = 0
    public var failed = 0
    /// Local asset vanished (deleted / dropped from a limited selection) - honest non-success.
    public var sourceMissing = 0
    /// The only remote copy is intentionally deleted/trashed - backup respects that, so does sync.
    public var skippedRemoteDeletion = 0
    /// The unresolved rows of this run, one per local identifier (newest revision), with their reasons.
    public var problems: [String: BackupFailedItem] = [:]
    /// Original filenames by local identifier, so the album list can name photos without a problem row.
    public var filenames: [String: String] = [:]

    public init() {}

    public init(
        total: Int,
        backedUp: Int,
        failed: Int,
        sourceMissing: Int,
        skippedRemoteDeletion: Int,
        problems: [String: BackupFailedItem] = [:],
        filenames: [String: String] = [:]
    ) {
        self.total = total
        self.backedUp = backedUp
        self.failed = failed
        self.sourceMissing = sourceMissing
        self.skippedRemoteDeletion = skippedRemoteDeletion
        self.problems = problems
        self.filenames = filenames
    }
}

/// Runs the standard backup pipeline (scan, dedupe preflight, and upload) for the given
/// local assets. It uses the same engine, runner, and manifest as full photo backup, so skip
/// decisions stay consistent between features. It must be cancellable via `stop()`.
public protocol AlbumSyncBackupExecuting: Sendable {
    func ensureBackedUp(
        localIdentifiers: [String],
        onProgress: @Sendable @escaping (BackupSyncProgress) -> Void
    ) async throws -> AlbumSyncBackupReport
    /// Resolves only settled assets whose upload manifest has no link. The proof stays transient.
    func remoteProofLinks(for localIdentifiers: [String]) async throws -> [String: AlbumSyncRemoteLink]
    func stop() async
}

public extension AlbumSyncBackupExecuting {
    func remoteProofLinks(for localIdentifiers: [String]) async throws -> [String: AlbumSyncRemoteLink] { [:] }
}

/// Remote (Proton) album operations the sync engine needs. Implemented by the backend package;
/// injected so this module remains independent of the concrete transport.
public protocol AlbumSyncRemoteAlbumOps: Sendable {
    /// The user's Proton albums with decrypted titles (for the same-name conflict pre-check).
    func listAlbums() async throws -> [AlbumSyncRemoteAlbum]
    /// Creates an album and returns its id. Must throw on failure - never a fake id.
    func createAlbum(name: String) async throws -> String
    /// Link ids of the album's current main photos (Live Photo motion parts stay nested).
    func childMainLinkIDs(albumID: String) async throws -> Set<String>
    /// Fresh deletion evidence only for links that are not current album members. Missing results are unknown.
    func remoteDeletionStates(for links: [AlbumSyncRemoteLink]) async throws -> [String: UploadRemoteDeletionState]
    /// Attaches existing remote photos (no media re-upload). Per-item failures are aggregated,
    /// never masked; "already a member" is reported as convergence.
    func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult
    /// Active photos of the account whose main file has the same bytes, by lowercase SHA-1 hex. Read-only; another
    /// device's copy of a shared photo has its own link with the same bytes. The answer can name related files and
    /// photos outside the album; the caller keeps only current album members.
    func activeMainLinkIDs(withSameContentAs sha1Hexes: Set<String>) async throws -> [String: Set<String>]
}

public extension AlbumSyncRemoteAlbumOps {
    func remoteDeletionStates(for links: [AlbumSyncRemoteLink]) async throws -> [String: UploadRemoteDeletionState] {
        [:]
    }
    /// Without a content index no other copy is known, and every photo attaches through its own link.
    func activeMainLinkIDs(withSameContentAs sha1Hexes: Set<String>) async throws -> [String: Set<String>] { [:] }
}

/// Maps local asset identifiers to their remote counterparts via the upload identity manifest.
public protocol AlbumSyncRemoteLinkLookup: Sendable {
    func remoteLinks(for localIdentifiers: [String]) async -> [String: AlbumSyncRemoteLink]
    func shutdown() async
}

public extension AlbumSyncRemoteLinkLookup {
    func shutdown() async {}
}

/// `AlbumSyncRemoteLinkLookup` over the shared `upload-manifest-v1.sqlite` (read-only role; the
/// dedupe pipeline owns writes). Opening a second WAL connection is safe and keeps this module
/// free of any backend dependency.
public final class UploadManifestRemoteLinkLookup: AlbumSyncRemoteLinkLookup, @unchecked Sendable {
    private let store: UploadIdentityManifestStore

    public init?(manifestURL: URL, policy: LibraryDatabasePolicy) {
        guard let store = UploadIdentityManifestStore(url: manifestURL, policy: policy) else { return nil }
        self.store = store
    }

    public func remoteLinks(for localIdentifiers: [String]) async -> [String: AlbumSyncRemoteLink] {
        var result: [String: AlbumSyncRemoteLink] = [:]
        result.reserveCapacity(localIdentifiers.count)
        for identifier in localIdentifiers {
            let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: identifier, resource: .primary)
            guard let record = store.record(for: source),
                let linkID = record.remoteLinkID, !linkID.isEmpty,
                let outcome = record.outcome.flatMap(UploadIdentityManifestStore.Outcome.init(rawValue:))
            else {
                continue
            }
            switch outcome {
            case .uploaded, .duplicateActive:
                result[identifier] = AlbumSyncRemoteLink(
                    uid: PhotoUID(volumeID: record.remoteVolumeID ?? "", nodeID: linkID),
                    sha1Hex: record.sha1Hex.isEmpty ? nil : record.sha1Hex,
                    isTrashed: false
                )
            case .duplicateTrashed:
                result[identifier] = AlbumSyncRemoteLink(
                    uid: PhotoUID(volumeID: record.remoteVolumeID ?? "", nodeID: linkID),
                    sha1Hex: record.sha1Hex.isEmpty ? nil : record.sha1Hex,
                    isTrashed: true
                )
            }
        }
        return result
    }

    public func shutdown() async {
        store.close()
    }
}
