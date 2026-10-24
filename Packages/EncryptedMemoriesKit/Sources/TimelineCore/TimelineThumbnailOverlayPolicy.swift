import GridCore
import PhotosCore

/// The single photo-domain to grid-overlay mapping used by macOS, iOS, and iPadOS.
package enum TimelineThumbnailOverlayPolicy {
    package static func overlay(for item: PhotoItem) -> GridThumbnailOverlay {
        GridThumbnailOverlay(
            durationText: item.isVideo ? durationText(for: item.durationSeconds) : nil,
            showsRAW: isRAW(item)
        )
    }

    package static func durationText(for seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0, seconds < Double(Int.max) else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(remainder))"
        }
        return "\(minutes):\(twoDigits(remainder))"
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
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
