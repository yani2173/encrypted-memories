import CoreGraphics

/// Platform-neutral command/event seam between an outer shell and a grid host.
///
/// The proxy is intentionally ID-based and generic: Core owns the command surface, while app/feature layers
/// decide what their item identity type is. It contains no renderer, view, cache, image, or platform framework
/// dependency.
@MainActor
public final class GridProxy<ItemID: Hashable & Sendable> {
    public init() {}

    private var firstContentReadyReported = false
    private var firstContentReadyDelivered = false
    private var pendingContentReadyRevision: UInt64?

    /// Frame of an item's cell in the shell/window content coordinate space, or nil if the cell is not visible.
    public var windowFrameForItem: ((ItemID) -> CGRect?)?

    /// Scrolls the grid so the item is vertically centered.
    public var scrollToItem: ((ItemID) -> Void)?

    /// Scrolls the grid to a flattened timeline index. Used by date navigation overlays; the host resolves the
    /// index through production geometry, so no outer UI duplicates grid layout math.
    public var scrollToFlatIndex: ((Int) -> Void)?

    /// Scrolls to the newest timeline position.
    public var scrollToLatest: (() -> Void)?

    /// Read-only layout-invariant snapshot of the grid's current scroll position. The shell stores it per route.
    public var currentScrollAnchor: (() -> GridScrollAnchor<ItemID>?)?

    /// One discrete zoom-in step. The host wires this to the same path as trackpad pinch-in.
    public var zoomIn: (() -> Void)?

    /// One discrete zoom-out step. The host wires this to the same path as trackpad pinch-out.
    public var zoomOut: (() -> Void)?

    /// Current density bounds for native menus. Hosts compute this from their live profile and level.
    public var zoomAvailability: (() -> (canZoomIn: Bool, canZoomOut: Bool))?

    /// Flip normal-level thumbnail content fit. This is a content-fit command only; it must not mutate grid
    /// level, zoom, scroll, phase, or geometry.
    public var toggleContentMode: (() -> Void)?

    /// Set the normal-level content-mode preference explicitly.
    public var setContentMode: ((TileContentDisplayMode) -> Void)?

    /// Query live content-mode state for the shell control.
    public var contentModeState: (() -> (mode: TileContentDisplayMode, toggleAvailable: Bool))?

    /// Grid-to-shell event fired once the first visible thumbnail is resident.
    ///
    /// Readiness is latched so a fast grid cannot lose the event before the shell finishes installing its
    /// handler. Replacing the handler after delivery does not replay an already-consumed launch event.
    public var onFirstContentReady: (() -> Void)? {
        didSet { deliverFirstContentReadyIfPossible() }
    }

    /// Fired whenever a newly installed content generation has produced its first visible resident thumbnail.
    /// Unlike `onFirstContentReady`, this repeats after data-source changes. Reports that arrive before the
    /// shell installs its handler are coalesced and replayed once, so the latest rendered generation is never
    /// lost during SwiftUI/AppKit mounting.
    public var onContentReady: ((UInt64) -> Void)? {
        didSet { deliverContentReadyIfPossible() }
    }

    /// Reports the first visible resident thumbnail. Duplicate reports are intentionally ignored.
    public func reportFirstContentReady() {
        guard !firstContentReadyReported else { return }
        firstContentReadyReported = true
        deliverFirstContentReadyIfPossible()
    }

    public func reportContentReady(revision: UInt64) {
        pendingContentReadyRevision = revision
        reportFirstContentReady()
        deliverContentReadyIfPossible()
    }

    public func invalidatePendingContentReady() {
        pendingContentReadyRevision = nil
        if !firstContentReadyDelivered { firstContentReadyReported = false }
    }

    private func deliverFirstContentReadyIfPossible() {
        guard firstContentReadyReported, !firstContentReadyDelivered, let onFirstContentReady else { return }
        firstContentReadyDelivered = true
        onFirstContentReady()
    }

    private func deliverContentReadyIfPossible() {
        guard let revision = pendingContentReadyRevision, let onContentReady else { return }
        pendingContentReadyRevision = nil
        onContentReady(revision)
    }

    /// Notifies the shell while the grid is presenting a live resize.
    public var liveResizeChanged: ((_ active: Bool) -> Void)?
}
