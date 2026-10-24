import Foundation

/// Optional backend capability: the hidden original of a photo or video that was edited in Photos. The photo library
/// backup uploads the original as a related file of the edited photo.
public protocol EditedPhotoOriginalProviding: Sendable {
    /// The original as a viewer item, or nil when the photo has no proven original. The viewer asks only for items
    /// that `mayHaveEditedOriginal`; a backend answers nil for any other item.
    func editedOriginal(of item: PhotoItem) async throws -> PhotoItem?
}

extension PhotoItem {
    /// Only a plain photo or video can offer its original: a Live Photo or a series keeps it in more than one file.
    public var mayHaveEditedOriginal: Bool { !isLivePhoto && !isBurstCandidate }
}
