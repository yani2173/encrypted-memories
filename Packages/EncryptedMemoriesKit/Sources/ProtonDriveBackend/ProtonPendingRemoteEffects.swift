import AlbumCore
import Foundation
import PhotosCore
import UploadCore

/// Applies pending-grid decisions to Proton: trash and restore of photos whose upload raced a delete, and
/// favorites or album adds that waited for an upload.
public struct ProtonPendingRemoteEffects: PendingRemoteEffects {
    private let trashProvider: (any TrashProvider)?
    private let favorites: (any FavoritesProvider)?
    private let albums: AlbumsRepository

    public init(facade: ProtonClientFacade) {
        self.init(
            trashProvider: facade.backend as? any TrashProvider, favorites: facade.backend as? any FavoritesProvider,
            albums: facade.albums)
    }

    init(trashProvider: (any TrashProvider)?, favorites: (any FavoritesProvider)?, albums: AlbumsRepository) {
        self.trashProvider = trashProvider
        self.favorites = favorites
        self.albums = albums
    }

    public func trash(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
        guard let trashProvider else { return .retrying(uids) }
        return await Self.runBatch(uids) { try await trashProvider.trash(uids) }
    }

    public func restore(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
        guard let trashProvider else { return .retrying(uids) }
        return await Self.runBatch(uids) { try await trashProvider.restore(uids) }
    }

    public func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult {
        guard let favorites else { return .retry }
        return await Self.run { try await favorites.setFavorites([uid], favorite) }
    }

    public func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult {
        await Self.run { try await albums.addPhotos([uid], to: albumID) }
    }

    static func run(_ operation: () async throws -> Void) async -> PendingEffectResult {
        do {
            try await operation()
            return .done
        } catch {
            return classify(error)
        }
    }

    /// A batch settles each photo on its own: only photos that Proton did not answer, or that were never sent, try
    /// again. Confirmed and refused photos are done.
    static func runBatch(_ uids: [PhotoUID], _ operation: () async throws -> Void) async -> PendingBatchEffectResult {
        do {
            try await operation()
            return .done
        } catch let error as DriveBatchActionError {
            return PendingBatchEffectResult(retry: Set(uids.filter { error.retryableLinkIDs.contains($0.nodeID) }))
        } catch {
            return classify(error) == .retry ? .retrying(uids) : .done
        }
    }

    /// Transport errors, 408, 429 and 5xx retry, as do unknown errors and batch answers without a status for
    /// every photo. Proton's per-item rejection of a batch (for example a photo already in or out of the trash)
    /// and other 4xx answers are final.
    static func classify(_ error: any Error) -> PendingEffectResult {
        if let batch = error as? DriveBatchActionError {
            return batch.retryableLinkIDs.isEmpty ? .permanentFailure : .retry
        }
        return DriveBatchActionError.isFinal(error) ? .permanentFailure : .retry
    }
}
