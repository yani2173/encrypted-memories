import Foundation
import PhotosCore

/// App-facing album operations. Reads and writes are deliberately split below at the transport
/// boundary: SDK 0.33.0 owns catalog/sharing/membership reads, while direct Photos HTTP remains only
/// for the write contracts the SDK does not expose.
public protocol PhotoAlbumMembershipProviding: Sendable {
    func albumMembershipTitles(for photoUID: PhotoUID) async throws -> [String]
}

public protocol AlbumOperations: PhotoAlbumMembershipProviding {
    var capabilities: AlbumCapabilities { get }

    func listAlbums() async throws -> [AlbumSummary]
    func listSharedWithMeAlbums() async throws -> [SharedAlbumSummary]
    func leaveSharedAlbum(_ album: AlbumNodeIdentifier) async throws
    func albumMemberships(for photoUIDs: [PhotoUID]) async throws -> [PhotoUID: Set<AlbumNodeIdentifier>]
    func createAlbum(name: String) async throws -> AlbumID
    func deleteAlbum(albumID: AlbumID) async throws
    func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws
    func removePhotos(_ photoUIDs: [PhotoUID], from albumID: AlbumID) async throws
    func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws
}

/// SDK-owned read seam. Core never imports SDK types.
public protocol AlbumCatalogBackend: Sendable {
    func listAlbums() async throws -> [AlbumSummary]
    func listSharedWithMeAlbums() async throws -> [SharedAlbumSummary]
    func leaveSharedAlbum(_ album: AlbumNodeIdentifier) async throws
    func albumMemberships(for photoUIDs: [PhotoUID]) async throws -> [PhotoUID: Set<AlbumNodeIdentifier>]
    /// The memberships from reads that start after this call. A write that depends on them needs this state.
    func currentAlbumMemberships(for photoUIDs: [PhotoUID]) async throws -> [PhotoUID: Set<AlbumNodeIdentifier>]
}

extension AlbumCatalogBackend {
    /// A backend that never shares a read answers both questions with the same read.
    public func currentAlbumMemberships(
        for photoUIDs: [PhotoUID]
    ) async throws -> [PhotoUID: Set<AlbumNodeIdentifier>] {
        try await albumMemberships(for: photoUIDs)
    }
}

/// Direct-HTTP write seam retained only for operations absent from the Swift API of SDK 0.33.0.
public protocol AlbumWriteBackend: Sendable {
    func createAlbum(name: String) async throws -> AlbumID
    func deleteAlbum(albumID: AlbumID) async throws
    func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws
    func removePhotos(_ photoUIDs: [PhotoUID], from albumID: AlbumID) async throws
    func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws
}
