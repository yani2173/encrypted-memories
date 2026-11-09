/// Controls animation of placeholders for known grid items.
public enum GridThumbnailPlaceholderPolicy {
    /// Only visible tiles that can still load animate. A failed tile stays static.
    public static func shouldAnimate(visibleLoadingCount: Int, reduceMotion: Bool) -> Bool {
        visibleLoadingCount > 0 && !reduceMotion
    }

    /// Position of the light along the upper-left to lower-right diagonal, in tile coordinates.
    public static func lightPosition(at time: Double) -> Double {
        guard time.isFinite else { return 0.5 }
        let period = 2.4
        let remainder = time.truncatingRemainder(dividingBy: period)
        let phase = (remainder < 0 ? remainder + period : remainder) / period
        return -0.25 + phase * 1.5
    }
}
