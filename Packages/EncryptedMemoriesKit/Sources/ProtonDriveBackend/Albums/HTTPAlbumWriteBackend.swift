import AlbumCore
import Foundation
import PhotosCore

/// `AlbumWriteBackend` over the app's direct-HTTP album operations.
///
/// SDK 0.32.1 owns listing, sharing and membership reads. This adapter intentionally contains
/// only the write contracts still absent from the SDK.
struct HTTPAlbumWriteBackend: AlbumWriteBackend {
    /// Supplied by the bridge: PUT the album's cover to an already-uploaded photo (cleartext LinkID, no crypto).
    let setCoverProvider: @Sendable (AlbumID, PhotoUID) async throws -> Void
    /// Album write service: create-album crypto + REST.
    let createProvider: @Sendable (String) async throws -> AlbumID
    /// Deletes only the album container. The Proton endpoint refuses the operation if doing so would delete
    /// photos that exist only inside the album; this adapter never enables the destructive force flag.
    let deleteProvider: @Sendable (AlbumID) async throws -> Void
    /// Album write service: add existing photos (re-encrypted link metadata, no media re-upload).
    /// Must throw when ANY photo fails to attach - callers must never mistake a partial add for success.
    let addProvider: @Sendable ([PhotoUID], AlbumID) async throws -> Void
    /// Removes album membership only. The photo remains in the user's timeline and storage.
    let removeProvider: @Sendable ([PhotoUID], AlbumID) async throws -> Void

    func createAlbum(name: String) async throws -> AlbumID {
        try await createProvider(name)
    }

    func deleteAlbum(albumID: AlbumID) async throws {
        try await deleteProvider(albumID)
    }

    func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws {
        try await addProvider(photoUIDs, albumID)
    }

    func removePhotos(_ photoUIDs: [PhotoUID], from albumID: AlbumID) async throws {
        try await removeProvider(photoUIDs, albumID)
    }

    func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws {
        try await setCoverProvider(albumID, photoUID)
    }
}
