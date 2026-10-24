import AppKit
import MediaFeedCore
import PhotosCore

extension VisibleThumbnailSession {
    /// The session's decoded image, drawn the same way as the feed's own thumbnails.
    public func memoryImage(for uid: PhotoUID) -> NSImage? {
        memoryDecoded(for: uid).map(MacThumbnailImageDecoder.image(from:))
    }

    public func cachedImage(for uid: PhotoUID) async -> NSImage? {
        await cachedDecoded(for: uid).map(MacThumbnailImageDecoder.image(from:))
    }

    public func visibleImage(for uid: PhotoUID) async -> NSImage? {
        await visibleDecoded(for: uid).map(MacThumbnailImageDecoder.image(from:))
    }
}
