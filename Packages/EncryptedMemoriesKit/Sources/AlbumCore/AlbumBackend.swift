import Foundation
import PhotosCore

/// App-facing album operations. Reads and writes are deliberately split below at the transport
/// boundary: SDK 0.31.1 owns catalog/sharing/membership reads, while direct Photos HTTP remains only
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
}

/// Direct-HTTP write seam retained only for operations absent from SDK 0.31.1.
public protocol AlbumWriteBackend: Sendable {
    func createAlbum(name: String) async throws -> AlbumID
    func deleteAlbum(albumID: AlbumID) async throws
    func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws
    func removePhotos(_ photoUIDs: [PhotoUID], from albumID: AlbumID) async throws
    func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws
}
