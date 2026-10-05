import AlbumCore
import Foundation
import PhotosCore
import UploadCore

/// Carries the albums of a series over to the standalone copies of its favorites.
///
/// The repository owns the album contract for the whole account: its membership read is the SDK catalog, and
/// its add throws unless every photo is a member afterwards. The dissolution therefore shares one album
/// semantic with the rest of the app instead of a second write path.
struct AlbumRepositorySeriesCarryOver: SeriesAlbumCarryOver {
    let repository: AlbumsRepository

    func albums(containing uid: PhotoUID) async throws -> [SeriesAlbumReference] {
        try await albums(containing: [uid])[uid] ?? []
    }

    /// One membership read for all photos; the repository caches it.
    func albums(containing uids: [PhotoUID]) async throws -> [PhotoUID: [SeriesAlbumReference]] {
        let memberships = try await repository.albumMemberships(for: uids)
        return memberships.mapValues { albums in
            albums.map { SeriesAlbumReference(volumeID: $0.volumeID, albumID: $0.nodeID) }
        }
    }

    /// Bypasses the repository's membership cache and refreshes it.
    func currentAlbums(containing uids: [PhotoUID]) async throws -> [PhotoUID: [SeriesAlbumReference]] {
        let memberships = try await repository.currentAlbumMemberships(for: uids)
        return memberships.mapValues { albums in
            albums.map { SeriesAlbumReference(volumeID: $0.volumeID, albumID: $0.nodeID) }
        }
    }

    func addPhotos(_ uids: [PhotoUID], toOwnAlbum albumID: String) async throws {
        guard !uids.isEmpty else { return }
        try await repository.addPhotos(uids, to: albumID)
    }

    /// One fresh catalog read. The listing holds only albums of the account's own library.
    func ownAlbumCovers() async throws -> [String: String] {
        let albums = try await repository.listAlbums()
        return Dictionary(
            albums.compactMap { album in album.coverPhotoID.map { (album.id, $0) } },
            uniquingKeysWith: { first, _ in first })
    }

    func setCover(_ uid: PhotoUID, ofOwnAlbum albumID: String) async throws {
        try await repository.setAlbumCover(albumID: albumID, photoUID: uid)
    }
}
