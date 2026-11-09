import CoreGraphics
import PhotosCore

/// Shared, platform-neutral policy for the full-screen viewer's staged, bounded image loading. No platform
/// re-derives "how big to decode" or "how far from the current page to load." Platform adapters own the fetch,
/// the decode call, and the cache; the sizes/tiers/window live here.
///
/// The staging is **thumbnail to preview to original on demand**. The grid thumbnail shows
/// instantly; the current page then loads a mid-size `preview` decoded to a screen-bounded size; the full original
/// is deferred (zoom/export only) so a page appearing during a swipe never triggers a full-resolution decode.
public enum ViewerImageLoadPolicy {
    /// Stable identity for a page load. Viewport changes must not cancel and restart the same network/decode
    /// request; the settled zoom path requests a larger representation on demand.
    public struct LoadIdentity: Equatable, Sendable {
        public let uid: PhotoUID
        public let isCurrent: Bool
        public let maxPixelSize: Int

        public init(uid: PhotoUID, isCurrent: Bool, maxPixelSize: Int) {
            self.uid = uid
            self.isCurrent = isCurrent
            self.maxPixelSize = max(1, maxPixelSize)
        }
    }

    /// Which quality tier is on screen for a page. `thumbnail` is the instant grid image (soft, upscaled);
    /// `preview` is the bounded mid-size display decode; `original` is the deferred full-resolution decode.
    public enum Tier: String, Sendable { case thumbnail, preview, original }

    /// Decode headroom over the fit-to-screen size, so a moderate pinch-zoom stays crisp without decoding the full
    /// original. Bounded on purpose - the original is never decoded just because a page appeared.
    public static let displayZoomHeadroom: CGFloat = 2

    /// Absolute pixel ceiling (longest side) for a display decode, so a huge panorama / RAW / burst frame can never
    /// blow the per-image memory even if the viewport reading is unavailable. ~3072² · 4 ≈ 36 MB worst case.
    public static let maxDisplayPixelSize = 3072

    /// Absolute pixel ceiling (longest side) for a ZOOMED-IN decode. Covers a typical 12-24 MP original fully
    /// (≤ 6144 longest side) while capping monster panoramas/48 MP originals at ~6144×4608·4 ≈ 113 MB -
    /// transient (one page, replaces the display entry in the same cost-limited cache).
    public static let maxZoomedPixelSize = 6144

    /// How many pages either side of the current one may load their display image. `0` = current only (the tightest
    /// bound: no fetch/decode fan-out to swipe-preview neighbours).
    public static let loadNeighborRadius = 0

    /// Whether a page at `distanceFromCurrent` (|pageIndex − currentIndex|) may load its display image now.
    public static func shouldLoadDisplay(distanceFromCurrent: Int) -> Bool {
        distanceFromCurrent <= loadNeighborRadius
    }

    /// A progressive viewer may replace its visible image only when the candidate has at least as many pixels
    /// along its longest side. This keeps a transition-sized preview from replacing a sharper grid thumbnail.
    public static func shouldReplaceDisplayedImage(
        currentLongestPixelSide: Int,
        candidateLongestPixelSide: Int
    ) -> Bool {
        candidateLongestPixelSide > 0 && candidateLongestPixelSide >= max(0, currentLongestPixelSide)
    }

    /// The bounded max longest-side pixel size to decode a viewer display image at, given the viewport in points and
    /// the display scale: screen-fit × headroom, clamped to `maxDisplayPixelSize`. A zero/unknown viewport falls back
    /// to the ceiling, so the decode is always bounded.
    public static func displayMaxPixelSize(viewportPoints: CGSize, scale: CGFloat) -> Int {
        let longestPoints = max(viewportPoints.width, viewportPoints.height)
        guard longestPoints > 0, scale.isFinite, scale > 0 else { return maxDisplayPixelSize }
        let px = Int((longestPoints * scale * displayZoomHeadroom).rounded())
        return min(maxDisplayPixelSize, max(1, px))
    }

    /// The bounded decode size for a SETTLED zoom level: what the screen actually needs at that zoom
    /// (fit-size × zoom, no extra headroom - the zoom already happened), clamped to `maxZoomedPixelSize`
    /// and never below the display tier's size. The decoder itself never upscales past the source, so a
    /// small original simply decodes fully.
    public static func zoomedMaxPixelSize(viewportPoints: CGSize, scale: CGFloat, zoom: CGFloat) -> Int {
        let base = displayMaxPixelSize(viewportPoints: viewportPoints, scale: scale)
        guard zoom.isFinite, zoom > 1 else { return base }
        let longestPoints = max(viewportPoints.width, viewportPoints.height)
        guard longestPoints > 0, scale.isFinite, scale > 0 else { return maxZoomedPixelSize }
        let px = Int((longestPoints * scale * zoom).rounded())
        return min(maxZoomedPixelSize, max(base, px))
    }
}
