#if canImport(UIKit)
    import MediaFeedCore
    import PhotosCore
    import UIKit

    extension VisibleThumbnailSession {
        /// The session's decoded image, drawn the same way as the feed's own thumbnails.
        public func memoryImage(for uid: PhotoUID) -> UIImage? {
            memoryDecoded(for: uid).map(UIKitThumbnailImageDecoder.image(from:))
        }

        public func cachedImage(for uid: PhotoUID) async -> UIImage? {
            await cachedDecoded(for: uid).map(UIKitThumbnailImageDecoder.image(from:))
        }

        public func visibleImage(for uid: PhotoUID) async -> UIImage? {
            await visibleDecoded(for: uid).map(UIKitThumbnailImageDecoder.image(from:))
        }
    }
#endif
