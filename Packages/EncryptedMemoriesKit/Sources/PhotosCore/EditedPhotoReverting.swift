import Foundation

/// Optional backend capability: the revert of an edited photo to its hidden original. The original becomes a new
/// photo, and the edited version moves to the Trash. The backend decides the name of the new photo.
public protocol EditedPhotoReverting: Sendable {
    /// Reverts `main` to `original`, the item that `EditedPhotoOriginalProviding` found for it. Throws when the pair
    /// is not proven or the revert did not finish; a later call with the same pair continues an unfinished revert.
    func revertToOriginal(of main: PhotoItem, original: PhotoItem) async throws
}
