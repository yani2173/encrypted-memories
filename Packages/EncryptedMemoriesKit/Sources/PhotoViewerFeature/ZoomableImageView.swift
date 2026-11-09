import AppKit
import SwiftUI
import VisionKit

/// AppKit owns native event details. Core owns the direction lock, threshold, and one-page-per-gesture contract.
enum AppKitViewerPageSwipeAdapter {
    /// What a scroll event did to the page swipe. The host delivers it after the tracker mutation ended, so a
    /// callback never runs while the tracker property is under exclusive access.
    struct Routing {
        let direction: ViewerPageSwipeDirection?
        let passesToSuper: Bool

        /// Reports a completed swipe through `onPageSwipe`. Returns whether the view's superclass must handle the
        /// event as well.
        func deliver(to onPageSwipe: (ViewerPageSwipeDirection) -> Void) -> Bool {
            if let direction { onPageSwipe(direction) }
            return passesToSuper
        }
    }

    static func route(_ event: NSEvent, with tracker: inout ViewerPageSwipeTracker) -> Routing {
        guard event.hasPreciseScrollingDeltas,
            event.momentumPhase.isEmpty,
            let phase = portablePhase(event.phase)
        else { return Routing(direction: nil, passesToSuper: true) }

        let x = ViewerPageSwipeTracker.deviceRelativeDelta(
            event.scrollingDeltaX,
            directionWasInverted: event.isDirectionInvertedFromDevice
        )
        let y = ViewerPageSwipeTracker.deviceRelativeDelta(
            event.scrollingDeltaY,
            directionWasInverted: event.isDirectionInvertedFromDevice
        )
        let update = tracker.consume(deltaX: x, deltaY: y, phase: phase)
        return Routing(direction: update.direction, passesToSuper: !update.consumesEvent)
    }

    private static func portablePhase(_ phase: NSEvent.Phase) -> ViewerPageSwipePhase? {
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.began) { return .began }
        if phase.contains(.mayBegin) { return .mayBegin }
        return nil
    }
}

/// Pinch-out-to-dismiss tracking of the image scroll view and the video view. It only reports progress
/// (1 = fullscreen, 0 = collapsed into the grid cell); the host's zoom overlay renders the shrink.
struct AppKitPinchDismissTracker {
    /// A small or quick pinch is enough to fly the viewer closed.
    static let closeProgress: CGFloat = 0.07

    private(set) var isDismissing = false
    private var progress: CGFloat = 0  // 0 = full size, grows as the user pinches out

    /// True while a dismiss runs, or when a magnify event with this `magnification` starts one: only a pinch-OUT does.
    func claims(magnification: CGFloat) -> Bool { isDismissing || magnification < 0 }

    /// What a magnify event did to the dismiss. The host reports it after the tracker mutation ended, so a callback
    /// never runs while the tracker property is under exclusive access.
    enum Outcome: Equatable {
        case none
        case began
        case changed(progress: CGFloat)  // 1 = fullscreen, 0 = the grid cell
        case ended(shouldClose: Bool)

        func report(began: () -> Void, changed: (CGFloat) -> Void, ended: (Bool) -> Void) {
            switch self {
            case .none: break
            case .began: began()
            case .changed(let progress): changed(progress)
            case .ended(let shouldClose): ended(shouldClose)
            }
        }
    }

    mutating func handle(phase: NSEvent.Phase, magnification: CGFloat) -> Outcome {
        switch phase {
        case .began:
            isDismissing = true
            progress = 0
            return .began
        case .changed:
            progress = max(0, progress - magnification)  // outward pinch = negative
            return .changed(progress: max(0, min(1, 1 - progress)))
        case .ended, .cancelled:
            let shouldClose = phase == .ended && progress > Self.closeProgress
            isDismissing = false
            return .ended(shouldClose: shouldClose)
        default:
            return .none
        }
    }
}

/// AppKit-backed zoomable image. `NSScrollView.allowsMagnification` gives us exactly the native
/// behaviour: pinch-to-zoom centred on the cursor and two-finger pan - smooth, no SwiftUI hacks.
/// A pinch-OUT while already at fit-scale flies the photo closed (live shrink + fade feedback).
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    /// Stable identity of the photo being shown. Image changes for the same identity are quality upgrades
    /// (thumbnail or preview to original); identity changes are navigation and must not crossfade old and new photos.
    var itemIdentity: String? = nil
    /// True once the full original is displayed. A transition from false to true for the same `itemIdentity` gets the
    /// shared viewer media reveal, instead of the old hard swap.
    var isSharp: Bool = false
    var transitionStyle: ViewerMediaTransitionStyle = .standard
    /// True while the host's zoom overlay is rendering the live dismiss: hide this image so it doesn't double the
    /// overlay's photo, but keep the scroll view itself hit-testable (alpha 1) so the pinch keeps delivering here.
    var isDismissing: Bool = false
    // Interactive pinch-out-to-dismiss: the gesture only reports progress (1 = fullscreen, 0 = collapsed into the
    // grid cell). The actual shrink-into-the-cell + grid fade is rendered by the shared zoom overlay in the host, so
    // the photo flies into its exact cell (not a local layer shrink toward a corner).
    var onPinchDismissBegan: () -> Void = {}
    var onPinchDismissChanged: (CGFloat) -> Void = { _ in }
    var onPinchDismissEnded: (Bool) -> Void = { _ in }
    /// Force-click (trackpad deep press) over the photo - starts a Live Photo's motion clip.
    var onForceClick: () -> Void = {}
    /// The force-click was released (finger lifted) - stops the motion clip, crossfading back to the still.
    var onForceClickEnded: () -> Void = {}
    /// Native horizontal trackpad paging. The AppKit adapter recognizes the gesture; Core owns its direction.
    var onPageSwipe: (ViewerPageSwipeDirection) -> Void = { _ in }
    /// Reports the displayed photo rect (aspect-fit area, magnification/pan-transformed) in the view's
    /// top-left-origin coordinate space whenever layout/zoom/pan changes it. Lets the host glue overlays
    /// (Live Photo motion layer) to the photo instead of the viewer.
    var onPhotoFrameChanged: ((CGRect) -> Void)? = nil
    /// Requests a bounded sharp representation once the native zoom exceeds fit scale.
    var onZoomChanged: ((CGFloat) -> Void)? = nil
    /// On-device Live Text for the displayed still. `nil` removes text interaction from the photo.
    var liveTextAnalysis: ImageAnalysis? = nil
    /// Highlights the recognized text and its detected items.
    var liveTextHighlighted = false

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ZoomScrollView()
        scrollView.onPinchDismissBegan = onPinchDismissBegan
        scrollView.onPinchDismissChanged = onPinchDismissChanged
        scrollView.onPinchDismissEnded = onPinchDismissEnded
        scrollView.onForceClick = onForceClick
        scrollView.onForceClickEnded = onForceClickEnded
        scrollView.onPageSwipe = onPageSwipe
        scrollView.onPhotoFrameChanged = onPhotoFrameChanged
        scrollView.onZoomChanged = onZoomChanged
        scrollView.pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = 10
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.automaticallyAdjustsContentInsets = false

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.image = image
        scrollView.documentView = imageView

        context.coordinator.imageView = imageView
        context.coordinator.itemIdentity = itemIdentity
        context.coordinator.isSharp = isSharp
        context.coordinator.updateLiveText(analysis: liveTextAnalysis, highlighted: liveTextHighlighted)
        scrollView.needsLayout = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if let z = scrollView as? ZoomScrollView {
            z.onPinchDismissBegan = onPinchDismissBegan
            z.onPinchDismissChanged = onPinchDismissChanged
            z.onPinchDismissEnded = onPinchDismissEnded
            z.onForceClick = onForceClick
            z.onForceClickEnded = onForceClickEnded
            z.onPageSwipe = onPageSwipe
            z.onPhotoFrameChanged = onPhotoFrameChanged
            z.onZoomChanged = onZoomChanged
            // Initial/refresh report, async: we're inside a SwiftUI view update and the callback writes @State.
            DispatchQueue.main.async { [weak z] in z?.reportPhotoFrame() }
        }
        guard let imageView = context.coordinator.imageView else { return }
        imageView.alphaValue = isDismissing ? 0 : 1  // hide only the image; the scroll view stays hit-testable
        if imageView.image !== image {
            let sameItem = context.coordinator.itemIdentity == itemIdentity
            let revealsOriginal = sameItem && !context.coordinator.isSharp && isSharp && !isDismissing
            if revealsOriginal {
                imageView.crossfadeToImage(image, style: transitionStyle)
            } else {
                imageView.image = image
            }
            // Reset zoom only when the photo changes. A same-item image swap is a quality upgrade;
            // preserving magnification keeps the user's zoom and pan stable.
            if !sameItem {
                scrollView.magnification = 1
            }
            scrollView.needsLayout = true
        }
        context.coordinator.itemIdentity = itemIdentity
        context.coordinator.isSharp = isSharp
        context.coordinator.updateLiveText(analysis: liveTextAnalysis, highlighted: liveTextHighlighted)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var imageView: NSImageView?
        var itemIdentity: String?
        var isSharp = false
        private var liveTextOverlay: ImageAnalysisOverlayView?

        /// Places the Live Text overlay inside the image view, so it follows magnification and pan, and tracks the
        /// image view's fitted image rect. Without an analysis the overlay is removed and no event reaches it.
        @MainActor func updateLiveText(analysis: ImageAnalysis?, highlighted: Bool) {
            guard let imageView else { return }
            guard let analysis else {
                liveTextOverlay?.removeFromSuperview()
                liveTextOverlay = nil
                return
            }
            let overlay: ImageAnalysisOverlayView
            if let existing = liveTextOverlay {
                overlay = existing
            } else {
                overlay = ImageAnalysisOverlayView(frame: imageView.bounds)
                overlay.autoresizingMask = [.width, .height]
                overlay.preferredInteractionTypes = .automaticTextOnly
                // The viewer toolbar owns the Show Text action; the system button would scale with the zoom.
                overlay.isSupplementaryInterfaceHidden = true
                overlay.trackingImageView = imageView
                imageView.addSubview(overlay)
                liveTextOverlay = overlay
            }
            if overlay.analysis !== analysis { overlay.analysis = analysis }
            if overlay.selectableItemsHighlighted != highlighted { overlay.selectableItemsHighlighted = highlighted }
        }
    }
}

private extension NSImageView {
    static let revealOverlayIdentifier = NSUserInterfaceItemIdentifier("PhotoViewerHighResolutionRevealOverlay")

    /// Crossfades a same-photo quality upgrade without rebuilding the scroll view, preserving the viewer's
    /// native pinch/pan surface and keeping the transition tuning shared with the Live Photo motion blend.
    func crossfadeToImage(_ newImage: NSImage, style: ViewerMediaTransitionStyle) {
        guard let oldImage = image else {
            image = newImage
            return
        }

        subviews
            .filter { $0.identifier == Self.revealOverlayIdentifier }
            .forEach { $0.removeFromSuperview() }

        let outgoing = NSImageView(frame: bounds)
        outgoing.identifier = Self.revealOverlayIdentifier
        outgoing.imageScaling = imageScaling
        outgoing.imageAlignment = imageAlignment
        outgoing.image = oldImage
        outgoing.alphaValue = 1
        outgoing.autoresizingMask = [.width, .height]

        image = newImage
        addSubview(outgoing)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = style.opacityDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            outgoing.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in outgoing.removeFromSuperview() }
        }
    }
}

/// Keeps the document view equal to the actual fitted media, lets `NSScrollView` grow/scroll it when magnified,
/// and turns a pinch-out at fit-scale into a "fly closed" dismiss.
final class ZoomScrollView: NSScrollView {
    var onPinchDismissBegan: () -> Void = {}
    var onPinchDismissChanged: (CGFloat) -> Void = { _ in }
    var onPinchDismissEnded: (Bool) -> Void = { _ in }
    var onForceClick: () -> Void = {}
    var onForceClickEnded: () -> Void = {}
    var onPageSwipe: (ViewerPageSwipeDirection) -> Void = { _ in }
    var onPhotoFrameChanged: ((CGRect) -> Void)?
    var onZoomChanged: ((CGFloat) -> Void)?
    /// Last reported photo rect - reports are de-duplicated so a steady frame never spams SwiftUI state.
    private var lastReportedPhotoFrame: CGRect = .null

    private var pinchDismiss = AppKitPinchDismissTracker()
    private var forceClickFired = false  // true between deep-press and release (drives hold-to-play)
    private var pageSwipeTracker = ViewerPageSwipeTracker()
    private var updatingZoomGeometry = false
    private var lastZoomViewport: CGSize = .zero
    private var lastFitSize: CGSize = .zero
    private var pendingVisibleAnchor: CGPoint?

    /// The displayed photo rect: the aspect-FIT area of the image inside the (magnified) document view,
    /// converted to this view's space and normalised to a top-left origin (the SwiftUI overlay space).
    func reportPhotoFrame() {
        guard let onPhotoFrameChanged,
            let dv = documentView as? NSImageView, let img = dv.image,
            img.size.width > 0, img.size.height > 0, bounds.height > 0
        else { return }
        var rect = dv.convert(dv.bounds, to: self)
        if !isFlipped { rect.origin.y = bounds.height - rect.maxY }
        if abs(rect.minX - lastReportedPhotoFrame.minX) < 0.5,
            abs(rect.minY - lastReportedPhotoFrame.minY) < 0.5,
            abs(rect.width - lastReportedPhotoFrame.width) < 0.5,
            abs(rect.height - lastReportedPhotoFrame.height) < 0.5
        {
            return
        }
        lastReportedPhotoFrame = rect
        onPhotoFrameChanged(rect)
    }

    /// Called by AppKit on every scroll AND magnification change of the clip view - the one central hook
    /// that sees all pan/zoom updates.
    override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        updateZoomContentGeometry()
        reportPhotoFrame()
    }

    /// AppKit constrains the clip origin as soon as its frame changes. Capture the visible media point before
    /// that mutation, then consume it from `layout()` after the new viewport and fitted document are known.
    override func setFrameSize(_ newSize: NSSize) {
        if magnification > minMagnification + 0.001,
            lastZoomViewport != .zero,
            lastFitSize != .zero,
            newSize != frame.size
        {
            let zoom = max(magnification, 0.001)
            pendingVisibleAnchor = ViewerZoomGeometry.normalizedVisibleAnchor(
                contentOrigin: CGPoint(
                    x: contentView.bounds.origin.x * zoom,
                    y: contentView.bounds.origin.y * zoom
                ),
                contentSize: CGSize(width: lastFitSize.width * zoom, height: lastFitSize.height * zoom),
                viewportSize: lastZoomViewport
            )
        }
        super.setFrameSize(newSize)
    }

    /// Trackpad deep press = hold-to-play: stage ≥ 2 starts the motion; releasing the finger (pressure relaxes
    /// below stage 2) stops it. The trackpad streams decreasing-stage events as the finger lifts, so this is the
    /// reliable release signal - no `mouseUp` override needed.
    override func pressureChange(with event: NSEvent) {
        super.pressureChange(with: event)
        if event.stage >= 2 {
            if !forceClickFired {
                forceClickFired = true
                onForceClick()  // Deep press starts playback.
            }
        } else if forceClickFired {
            forceClickFired = false
            onForceClickEnded()  // Release stops playback.
        }
    }

    override func layout() {
        super.layout()
        updateZoomContentGeometry()
        reportPhotoFrame()
    }

    /// Makes the native document's edges equal the actual media edges. `NSScrollView` then supplies the native
    /// magnification, pan, and rubber-band behavior without giving the aspect-fit letterbox its own scroll range.
    func updateZoomContentGeometry() {
        guard !updatingZoomGeometry, !pinchDismiss.isDismissing,
            let imageView = documentView as? NSImageView,
            let image = imageView.image,
            image.size.width > 0, image.size.height > 0
        else { return }
        // `bounds` is expressed in magnified document coordinates. `frame` remains the physical
        // viewport size and therefore keeps the fitted document stable while the user zooms.
        let viewport = contentView.frame.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        let fitSize = ViewerZoomGeometry.aspectFitSize(mediaSize: image.size, viewportSize: viewport)
        guard fitSize != .zero else { return }

        updatingZoomGeometry = true
        let oldMagnification = max(magnification, 0.001)
        let oldViewport = lastZoomViewport == .zero ? viewport : lastZoomViewport
        let oldFit = lastFitSize == .zero ? fitSize : lastFitSize
        let oldVisibleOrigin = CGPoint(
            x: contentView.bounds.origin.x * oldMagnification,
            y: contentView.bounds.origin.y * oldMagnification
        )
        let visibleAnchor =
            pendingVisibleAnchor
            ?? ViewerZoomGeometry.normalizedVisibleAnchor(
                contentOrigin: oldVisibleOrigin,
                contentSize: CGSize(width: oldFit.width * oldMagnification, height: oldFit.height * oldMagnification),
                viewportSize: oldViewport
            )
        imageView.frame = CGRect(origin: .zero, size: fitSize)
        // NSClipView content insets use document coordinates, so compare the fitted document with
        // the viewport divided by the current magnification. The visible result stays centered.
        let visibleDocumentSize = CGSize(
            width: viewport.width / max(magnification, 0.001),
            height: viewport.height / max(magnification, 0.001)
        )
        let insets = ViewerZoomGeometry.centeredInsets(
            contentSize: fitSize,
            viewportSize: visibleDocumentSize
        )
        contentView.contentInsets = NSEdgeInsets(
            top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right)
        if oldMagnification > minMagnification + 0.001,
            lastZoomViewport != .zero,
            viewport != lastZoomViewport || fitSize != lastFitSize
        {
            let scaledContent = CGSize(
                width: fitSize.width * oldMagnification,
                height: fitSize.height * oldMagnification
            )
            let rebased = ViewerZoomGeometry.rebasedOrigin(
                anchor: visibleAnchor,
                contentSize: scaledContent,
                viewportSize: viewport
            )
            contentView.scroll(
                to: CGPoint(
                    x: rebased.x / oldMagnification,
                    y: rebased.y / oldMagnification
                ))
        }
        pendingVisibleAnchor = nil
        lastZoomViewport = viewport
        lastFitSize = fitSize
        updatingZoomGeometry = false
    }

    override func scrollWheel(with event: NSEvent) {
        guard magnification <= minMagnification + 0.001 else {
            super.scrollWheel(with: event)
            return
        }
        let routing = AppKitViewerPageSwipeAdapter.route(event, with: &pageSwipeTracker)
        if routing.deliver(to: onPageSwipe) { super.scrollWheel(with: event) }
    }

    override func magnify(with event: NSEvent) {
        let atBase = magnification <= minMagnification + 0.001
        // Intercept only a pinch-OUT that starts at fit-scale - otherwise let the scroll view zoom.
        guard atBase, pinchDismiss.claims(magnification: event.magnification) else {
            super.magnify(with: event)
            onZoomChanged?(magnification)
            return
        }
        // This view does not animate itself; it only reports progress. The host renders the live shrink into the
        // exact grid cell plus the grid fade behind, via the shared zoom overlay (the gesture keeps being delivered
        // here while the host renders the viewer invisible).
        let outcome = pinchDismiss.handle(phase: event.phase, magnification: event.magnification)
        outcome.report(began: onPinchDismissBegan, changed: onPinchDismissChanged, ended: onPinchDismissEnded)
    }
}
