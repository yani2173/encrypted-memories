import AlbumCore
import Foundation
import PhotosCore

/// A final catalog-read failure, separate from album write outcomes and partial success.
public struct AlbumFailurePresentation: Sendable, Equatable {
    public let message: String
    public let canRetry: Bool

    public static func read(_ error: any Error) -> Self? {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            return nil
        }
        if let albumError = error as? AlbumError {
            if let cause = albumError.writeCause {
                switch cause.kind {
                case .cancelled, .network(code: URLError.cancelled.rawValue): return nil
                default: break
                }
            }
            switch albumError {
            case .unsupported, .sharedAlbumReadOnly:
                return Self(message: albumError.localizedDescription, canRetry: false)
            default: break
            }
        }
        // An unclassified failure is not proof that another read cannot succeed.
        return Self(message: L10n.string("albums.load_failed_message"), canRetry: true)
    }
}
