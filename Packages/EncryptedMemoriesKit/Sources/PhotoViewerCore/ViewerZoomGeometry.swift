import CoreGraphics

/// Platform-neutral geometry for a viewer's zoom content.
///
/// Native scroll views own the gesture and rubber-band physics. This type only describes the actual
/// aspect-fit media rectangle and the settled origins that keep its outer edges as the pan boundary.
public enum ViewerZoomGeometry {
    /// Returns the largest aspect-preserving media size contained by `viewportSize`.
    /// Invalid or non-finite input produces `.zero`.
    public static func aspectFitSize(mediaSize: CGSize, viewportSize: CGSize) -> CGSize {
        guard isValidSize(mediaSize), isValidSize(viewportSize) else { return .zero }
        let scale = min(viewportSize.width / mediaSize.width, viewportSize.height / mediaSize.height)
        guard scale.isFinite, scale > 0 else { return .zero }
        return CGSize(width: mediaSize.width * scale, height: mediaSize.height * scale)
    }

    /// Returns the centered aspect-fit media rectangle inside `viewport`.
    /// Invalid or non-finite input produces `.zero`.
    public static func aspectFitRect(mediaSize: CGSize, in viewport: CGRect) -> CGRect {
        let fitted = aspectFitSize(mediaSize: mediaSize, viewportSize: viewport.size)
        guard fitted != .zero, isFinite(viewport) else { return .zero }
        return CGRect(
            x: viewport.midX - fitted.width / 2,
            y: viewport.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    /// Returns the settled content origin for a proposed pan.
    ///
    /// A smaller axis is centered. A larger axis is clamped from its first media edge to its last media edge.
    /// The result is expressed in the same content coordinate system as `proposedOrigin`.
    public static func settledOrigin(
        proposedOrigin: CGPoint,
        contentSize: CGSize,
        viewportSize: CGSize
    ) -> CGPoint {
        guard isFinite(proposedOrigin), isValidSize(contentSize), isValidSize(viewportSize) else { return .zero }
        return CGPoint(
            x: settledAxisOrigin(proposed: proposedOrigin.x, content: contentSize.width, viewport: viewportSize.width),
            y: settledAxisOrigin(proposed: proposedOrigin.y, content: contentSize.height, viewport: viewportSize.height)
        )
    }

    /// Captures the media point at the viewport center as normalized coordinates.
    /// Centered negative origins on a smaller axis therefore resolve to `0.5`.
    public static func normalizedVisibleAnchor(
        contentOrigin: CGPoint,
        contentSize: CGSize,
        viewportSize: CGSize
    ) -> CGPoint {
        guard isFinite(contentOrigin), isValidSize(contentSize), isValidSize(viewportSize) else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        return CGPoint(
            x: unit((contentOrigin.x + viewportSize.width / 2) / contentSize.width),
            y: unit((contentOrigin.y + viewportSize.height / 2) / contentSize.height)
        )
    }

    /// Rebases a normalized visible anchor after a viewport or fitted-media size change.
    public static func rebasedOrigin(
        anchor: CGPoint,
        contentSize: CGSize,
        viewportSize: CGSize
    ) -> CGPoint {
        guard isFinite(anchor), isValidSize(contentSize), isValidSize(viewportSize) else { return .zero }
        let proposed = CGPoint(
            x: unit(anchor.x) * contentSize.width - viewportSize.width / 2,
            y: unit(anchor.y) * contentSize.height - viewportSize.height / 2
        )
        return settledOrigin(
            proposedOrigin: proposed,
            contentSize: contentSize,
            viewportSize: viewportSize
        )
    }

    /// Returns the centered edge inset for native scroll views whose content is smaller than the viewport.
    /// Larger axes have no inset because their edges are scrollable bounds.
    public static func centeredInsets(
        contentSize: CGSize, viewportSize: CGSize
    ) -> (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        guard isValidSize(contentSize), isValidSize(viewportSize) else {
            return (0, 0, 0, 0)
        }
        let horizontal = max(0, (viewportSize.width - contentSize.width) / 2)
        let vertical = max(0, (viewportSize.height - contentSize.height) / 2)
        return (vertical, horizontal, vertical, horizontal)
    }

    /// Returns whether a currently displayed media rect is larger than its fit rect.
    /// This is used by native video adapters to leave zoomed content to AVKit's own pan surface.
    public static func isZoomed(currentRect: CGRect, fitRect: CGRect, tolerance: CGFloat = 1) -> Bool {
        guard isFinite(currentRect), isFinite(fitRect), currentRect.width > 0, currentRect.height > 0,
            fitRect.width > 0, fitRect.height > 0, tolerance.isFinite, tolerance >= 0
        else { return false }
        return currentRect.width > fitRect.width + tolerance || currentRect.height > fitRect.height + tolerance
    }

    private static func settledAxisOrigin(proposed: CGFloat, content: CGFloat, viewport: CGFloat) -> CGFloat {
        guard proposed.isFinite, content.isFinite, viewport.isFinite, content > 0, viewport > 0 else { return 0 }
        guard content > viewport else { return (content - viewport) / 2 }
        return min(max(proposed, 0), content - viewport)
    }

    private static func unit(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }

    private static func isValidSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.size.width.isFinite && rect.size.height.isFinite
    }
}
