import CoreGraphics

/// Shared semantics for the viewer's one-finger drag-to-dismiss interaction.
///
/// With the media unzoomed, a downward drag sticks the media to the finger: it translates and shrinks a little.
/// On release, the policy chooses between restoring the position and closing the viewer.
/// Platform adapters own recognizers and transforms; this type owns thresholds and release decisions.
public enum ViewerDragDismissPolicy {
    /// A drag must travel at least this far (points) before it can take the media, so a tap with a little jitter
    /// never grabs it.
    public static let engageDistance: CGFloat = 8

    /// Vertical dominance required to engage. A value slightly below one accepts a naturally diagonal downward
    /// swipe while a clearly horizontal drag stays with the pager.
    public static let verticalDominance: CGFloat = 0.9

    /// Release dismisses when the drag travelled at least this fraction of the viewport height…
    public static let dismissDistanceFraction: CGFloat = 0.16

    /// …OR the downward release velocity (points/second) is at least this - a quick flick closes early.
    public static let dismissVelocity: CGFloat = 750

    /// The media never shrinks below this while attached to the finger (so it stays clearly the same photo).
    public static let minimumDisplayScale: CGFloat = 0.6

    /// Spring-back animation parameters (duration seconds, damping 0…1) for a below-threshold release.
    public static let springBackDuration: Double = 0.32
    public static let springBackDamping: CGFloat = 0.82

    /// Whether a drag translation should take the media: only when it is not zoomed in (panning owns that), and
    /// the drag is a clear, past-the-engage-distance vertical gesture (so horizontal paging keeps its swipe).
    public static func engages(translation: CGSize, isZoomedIn: Bool) -> Bool {
        guard !isZoomedIn else { return false }
        let dx = abs(translation.width)
        let dy = abs(translation.height)
        guard dx.isFinite, dy.isFinite else { return false }
        return dy >= engageDistance && dy >= dx * verticalDominance
    }

    /// Chooses the dismiss recognizer early enough that a slightly diagonal downward swipe does not become a page
    /// swipe. Distance and release checks still protect against taps and accidental closure.
    public static func prefersDismissalAxis(velocity: CGSize) -> Bool {
        let dx = abs(velocity.width)
        let dy = abs(velocity.height)
        guard dx.isFinite, dy.isFinite, dy > 0 else { return false }
        return dy >= dx * verticalDominance
    }

    /// Normalized drag progress 0…1 from the vertical travel over the viewport height.
    public static func progress(translationY: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0, translationY.isFinite else { return 0 }
        return min(1, max(0, abs(translationY) / viewportHeight))
    }

    /// The on-screen scale while attached: shrinks gently with progress, floored so it never collapses.
    public static func displayScale(progress: CGFloat) -> CGFloat {
        let p = min(1, max(0, progress))
        return max(minimumDisplayScale, 1 - p * (1 - minimumDisplayScale))
    }

    /// The release decision: dismiss when the drag travelled far enough downward OR was flicked down fast enough.
    /// A degenerate reading never spuriously closes the viewer.
    public static func shouldDismiss(translationY: CGFloat, velocityY: CGFloat, viewportHeight: CGFloat) -> Bool {
        guard viewportHeight > 0, translationY.isFinite, velocityY.isFinite else { return false }
        if translationY >= viewportHeight * dismissDistanceFraction { return true }
        return velocityY >= dismissVelocity && translationY > 0
    }
}
