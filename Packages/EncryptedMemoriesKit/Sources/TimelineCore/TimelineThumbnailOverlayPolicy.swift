import GridCore
import PhotosCore

/// The single photo-domain to grid-overlay mapping used by macOS, iOS, and iPadOS.
package enum TimelineThumbnailOverlayPolicy {
    package static func overlay(for item: PhotoItem) -> GridThumbnailOverlay {
        GridThumbnailOverlay(durationText: item.durationText, showsRAW: isRAW(item))
    }

    /// The grid shows the length of a video like every other screen of the library.
    package static func durationText(for seconds: Double?) -> String? {
        PhotoItem.durationText(for: seconds)
    }

    private static func isRAW(_ item: PhotoItem) -> Bool {
        if item.tags.contains(.raw) { return true }
        switch item.mediaType.lowercased() {
        case "image/x-adobe-dng", "image/dng", "image/adobe-dng":
            return true
        default:
            return false
        }
    }
}
