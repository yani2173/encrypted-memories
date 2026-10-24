import AppKit
import GridCore
import MediaFeedCore
import MetalGridTextureAppKitAdapter
import MetalKit
import PhotosCore
import TimelineCore

/// A one-shot viewport placement applied after layout geometry becomes valid.
///   - `.preserve`: keep the current scroll position (the default for incremental data updates).
///   - `.newest`: place the viewport at the newest (bottom) end exactly once (a route's first visit / launch).
///   - `.oldest`: place bounded/read-order routes at the top-leading end exactly once.
///   - `.restore(anchor)`: re-pin a remembered photo anchor (returning to a previously-visited route so it
///     reopens exactly where the user left it).
enum GridInitialViewport: Equatable {
    case preserve
    case newest
    case oldest
    case restore(GridScrollAnchor<PhotoUID>)
}

/// A native `NSScrollView` owns scroll physics over a transparent, content-sized document spacer.
/// A viewport-sized `MetalGridView` draws only the visible items from the scroll origin.
final class MetalGridScrollHost: NSView {
    let coordinator: MetalGridCoordinator
    private let metalView: MetalGridView
    private let scrollView = MetalGridBlockingScrollView()
    private let spacer = MetalGridDocumentSpacer()
    /// The event-handling document spacer - the view that owns a native drag-out session
    /// (`beginDraggingSession` must be invoked on the view receiving the mouse events).
    var documentSpacer: NSView { spacer }
    private weak var wiredImageAvailabilitySource: MetalGridDataSource?

    var onHUD: ((MetalGridHUD) -> Void)? {
        didSet { coordinator.onHUD = onHUD }
    }
    /// Production click routing (content point, click count, modifiers).
    var onCellClick: ((CGPoint, Int, GridClickModifiers) -> Void)?
    /// Routes drag selection in engine layout coordinates.
    var onMarqueeBegan: ((GridClickModifiers) -> Void)?
    var onMarqueeChanged: ((CGRect) -> Void)?
    var onMarqueeEnded: (() -> Void)?
    /// DRAG-OUT: fired when a press crosses the marquee threshold. Receives the raw AppKit event
    /// and the press point converted to layout coordinates; returns true when a native drag-out
    /// session claimed the gesture (the spacer then suppresses marquee + click).
    var onDragOutThreshold: ((NSEvent, CGPoint) -> Bool)?
    /// The translucent selection rectangle drawn over the grid during a marquee drag (a passive overlay on the
    /// scroll document, so it scrolls with the content it's selecting).
    private let marqueeView = MetalGridMarqueeView()
    /// Fired on any viewport change (scroll / resize / level) so overlays (month labels, a11y) reposition.
    var onViewportChanged: (() -> Void)?
    /// The level the live pinch settled on - so the SwiftUI `level` binding stays in sync after a commit.
    var onZoomCommit: ((Int) -> Void)?

    /// The pre-commit level whose lingering SwiftUI `@Binding level` echo must be ignored after a host-led
    /// commit. A pinch advances `coordinator.level` to the settled level and pushes it to the binding. Until
    /// SwiftUI propagates that write, an `updateNSView` pass can deliver the stale pre-commit value and issue a
    /// second viewport-centre zoom. The guard is armed only when the level changes and is consumed by
    /// `reconcileLevelBinding`.
    /// See `LevelBindingReconciler`.
    private var pendingLevelEcho: Int?
    private var gridProfileResolver: TimelineGridProfileResolver?
    private var pendingResolvedGridProfile: GridLevelProfile?
    private var fillOrder: GridFillOrder

    /// Leading obstruction inset for the floating sidebar. It is shared by hit testing, input conversion, and
    /// settled layout. The Metal surface remains full width while the settled grid uses the inset width.
    var eventLeadingInset: CGFloat = 0 {
        didSet { applyLeadingInsetChange(from: oldValue) }
    }

    /// The window's translucent toolbar height, plumbed from `MainView`. Mirrored to the coordinator/engine so the
    /// first row rests below the toolbar (the engine's `contentHeight` grows by it). Re-lays content unless a
    /// resize/sidebar/zoom presentation is mid-flight (those re-apply content size on their own settle). Set once
    /// at open and effectively constant thereafter, so a plain relayout is enough - no anchor gymnastics.
    var topBarInset: CGFloat = 0 {
        didSet {
            guard abs(topBarInset - oldValue) > 0.5 else { return }
            coordinator.topBarInset = topBarInset
            guard !coordinator.presentationResizeActive, !coordinator.isSidebarResizing,
                !coordinator.isZoomingLive, !coordinator.isCommitBridging, !coordinator.isResizeSettling
            else { return }
            applyContentSize(coordinator.contentSize())
        }
    }
    /// Extra leading space between the sidebar and the grid for normal levels (L0-L3); the
    /// dense square overviews (L4-L5) go edge-to-edge. The coordinator applies it only when a sidebar is present.
    nonisolated static let normalLevelLeadingGap: CGFloat = 16

    private var streamingTick: CADisplayLink?
    private(set) var framePump = GridFramePump()
    /// The grid is laid out oldest at top-left and newest at bottom-right. It opens and re-pins at the
    /// newest edge until the user scrolls away.
    private var stickToBottom = true

    /// One-shot viewport policy installed by a route or data-source switch. The policy is consumed only after
    /// layout geometry is valid, then returns to `.preserve` so the user can scroll freely.
    private var pendingInitialViewport: GridInitialViewport = .preserve

    /// The viewport size at the previous `layout()`. Resize handling uses it to rebase the
    /// scroll so the same logical region stays visible after slotSide
    /// changes). `.zero` until the first layout.
    /// The grid viewport's frame in screen coordinates at the previous `layout()`. It lets the engine detect
    /// which edge moved so the stationary edge holds the anchor and the moving edge
    /// clips/reveals. `.zero` until the first layout with a window.
    private var lastViewportScreenFrame: NSRect = .zero

    /// The viewport screen frame captured at the start of the current live window resize. Used for the single
    /// settle rebase on `didEndLiveResize`. `.zero` outside a live resize.
    private var liveResizeStartFrame: NSRect = .zero
    /// Release-settle (detent-crossing reflow) clock: the tiles fly from the scaled frame to the settled layout.
    private var resizeSettleStart: CFTimeInterval = 0
    private let resizeSettleDuration: CFTimeInterval = 0.22
    /// Sidebar open/close clock: the full Metal surface interpolates to the canonical obstructed layout.
    private var sidebarResizeStart: CFTimeInterval = 0
    /// Clock of the sidebar transition. Tests replace it to step a transition without waiting.
    var sidebarClock: () -> CFTimeInterval = CACurrentMediaTime
    /// The enclosing split view's sidebar edge, read per frame while a sidebar toggle runs. Nil otherwise, and
    /// when the grid is not hosted in a split view (the coordinator then runs its own clock).
    private var sidebarEdgeSource: SplitViewSidebarEdgeSource?

    // Live focus-row pinch gesture state (engine-owned GridZoomTransaction).
    private var pinchActive = false
    private var liveScrollInputActive = false
    private var marqueeInputActive = false
    private var reportedFeedInteractionActive = false
    /// This host's identity in the shared feed's interaction aggregate (one owner per grid host).
    private let interactionOwner = ThumbnailInteractionOwner()
    private var pinchBaseLevel = 0
    private var pinchCumulativeMagnification: CGFloat = 0

    // The driver keeps eligible in-band pinch segments continuous across detents.
    private var pinchDriver = PinchLiveZoomDriver()
    // The first resolved direction selects one route for the complete gesture.
    private enum PinchMode { case undecided, lattice, reflow, overviewDissolve }
    private var pinchMode: PinchMode = .undecided
    private var pinchSettling = false
    private var pinchBuiltSegment: (Int, Int)?
    private var pinchChainBand: (lo: Int, hi: Int) = (0, 0)
    private var pinchPrevMagnifyTime: CFTimeInterval = 0
    private var pinchAdvancePrevTime: CFTimeInterval = 0

    // Overview dissolve state.
    private var pinchOverviewSource = 0
    private var pinchOverviewTarget = 0
    private var pinchOverviewQ: Double = 0
    private var pinchOverviewSettleFrom: Double = 0
    private var pinchOverviewSettleTo: Double = 0
    private var pinchOverviewSettleStart: CFTimeInterval = 0
    private let pinchOverviewSettleDuration: CFTimeInterval = 0.16
    // Reflow returns an over-zoomed presentation to level 0 after release.
    private var pinchReflowSettleFrom: CGFloat = 0
    private var pinchReflowSettleStart: CFTimeInterval = 0
    private let pinchReflowSettleDuration: CFTimeInterval = 0.18
    /// Time of the last magnify event, used to suppress residual scroll input.
    private var lastMagnifyEventTime: CFTimeInterval = 0
    /// Scroll origin held during a pinch and its suppression window.
    private var scrollLockOrigin: CGPoint?
    /// Start time for the post-release geometry bridge.
    private var bridgeStart: CFTimeInterval = 0
    private let bridgeDuration: CFTimeInterval = GridZoomCommitBridge.duration

    init?(
        device: MTLDevice, dataSource: MetalGridDataSource, budget: MetalGridBudget = .default,
        gridProfile: GridLevelProfile,
        fillOrder: GridFillOrder = .newestBottomTrailing,
        gridProfileResolver: TimelineGridProfileResolver? = nil
    ) {
        guard
            let coordinator = MetalGridCoordinator(
                device: device, dataSource: dataSource, budget: budget,
                gridProfile: gridProfile, fillOrder: fillOrder,
                memoryGovernor: .shared)
        else { return nil }
        self.coordinator = coordinator
        self.metalView = MetalGridView(frame: .zero, device: device)
        self.gridProfileResolver = gridProfileResolver
        self.fillOrder = fillOrder
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layer?.backgroundColor = MetalGridPalette.background.cgColor  // uniform Apple-like dark surface
        installImageAvailabilityCallback(on: dataSource)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Decline events under the translucent sidebar and under the translucent toolbar. The grid renders beneath
    /// both, but a click there belongs to the sidebar or the window chrome: it must never select or drag the photo
    /// underneath. Coordinates inside the visible grid remain unchanged, preserving click-to-photo routing and the
    /// pinch anchor.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if Self.declinesEvent(
            atX: point.x, distanceFromTop: isFlipped ? local.y : bounds.height - local.y,
            leadingInset: eventLeadingInset, topInset: topBarInset)
        {
            return nil
        }
        return super.hitTest(point)
    }

    /// Whether an event at this position lies under the sidebar (`leadingInset`, in the superview's x) or under the
    /// toolbar (`topInset`, measured from the top edge).
    static func declinesEvent(
        atX x: CGFloat, distanceFromTop: CGFloat, leadingInset: CGFloat, topInset: CGFloat
    ) -> Bool {
        (leadingInset > 0 && x < leadingInset) || (topInset > 0 && distanceFromTop < topInset)
    }

    private func setUp() {
        // The shared frame pump owns invalidation and drawable retries; AppKit supplies the display tick.
        metalView.frame = bounds
        metalView.autoresizingMask = [.width, .height]
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = true
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        // Uncovered pixels clear to the grid background (the inter-cell gap + letterbox colour), so a transient
        // coverage gap during a zoom transition is never a black flash.
        metalView.clearColor = MetalGridPalette.clearColor
        metalView.delegate = coordinator
        addSubview(metalView)

        // Scroll view (front): fully transparent so the Metal view shows through.
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        // Keep the clip origin at zero. The grid owns its leading obstruction inset and top frost overlay;
        // automatic safe-area content insets would apply that obstruction twice.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        spacer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        scrollView.documentView = spacer
        addSubview(scrollView, positioned: .above, relativeTo: metalView)
        marqueeView.isHidden = true
        spacer.addSubview(marqueeView)  // drawn over the photos (the spacer is the front, transparent document)

        coordinator.clipView = scrollView.contentView
        coordinator.metalView = metalView
        coordinator.onRequestRedraw = { [weak self] in self?.requestFrame() }
        coordinator.normalLevelLeadingGap = Self.normalLevelLeadingGap
        coordinator.onContentSizeChange = { [weak self] size in
            // Freeze content size during width and sidebar scaling.
            guard let self, !self.coordinator.presentationResizeActive, !self.coordinator.isSidebarResizing else {
                return
            }
            self.applyContentSize(size)
        }

        spacer.onClick = { [weak self] point, clickCount, modifiers in
            guard let self else { return }
            // Convert render coordinates to layout coordinates.
            self.onCellClick?(
                CGPoint(x: point.x - self.coordinator.leadingObstructionInset, y: point.y), clickCount, modifiers)
        }
        spacer.onMarqueeBegan = { [weak self] mods in
            guard let self else { return }
            self.marqueeInputActive = true
            self.updateFeedInteractionState()
            self.marqueeView.isHidden = false
            self.onMarqueeBegan?(mods)
        }
        spacer.onMarqueeChanged = { [weak self] rawRect in
            guard let self else { return }
            self.marqueeView.frame = rawRect
            self.marqueeView.needsDisplay = true
            let inset = self.coordinator.leadingObstructionInset
            self.onMarqueeChanged?(rawRect.offsetBy(dx: -inset, dy: 0))
        }
        spacer.onMarqueeEnded = { [weak self] in
            guard let self else { return }
            self.marqueeInputActive = false
            self.updateFeedInteractionState()
            self.marqueeView.isHidden = true
            self.onMarqueeEnded?()
        }
        spacer.onDragThresholdArbiter = { [weak self] event, spacerPoint in
            guard let self, let onDragOut = self.onDragOutThreshold else { return false }
            // Same render-to-layout conversion as `onClick` (sidebar + gap offset).
            let contentPoint = CGPoint(
                x: spacerPoint.x - self.coordinator.leadingObstructionInset, y: spacerPoint.y)
            return onDragOut(event, contentPoint)
        }
        spacer.onMagnify = { [weak self] event in self?.handleMagnify(event) }
        // Swallow scroll whenever a pinch could leak into one. Wired on both the document spacer and the
        // scroll view itself (two interception points) so trackpad scroll/inertia that bypasses the spacer
        // is still caught. Blocks: the live pinch (`pinchActive` / the engine's live-zoom transaction), a
        // grace window after the last magnify OR the commit, and post-pinch MOMENTUM (the inertia that
        // keeps scrolling the committed grid wildly when you push past the largest/densest stage).
        let block: (NSEvent) -> Bool = { [weak self] event in
            guard let self else { return false }
            if pinchActive || pinchSettling || coordinator.isZoomingLive || coordinator.isCommitBridging
                || coordinator.isResizeSettling || coordinator.isSidebarResizing
            {
                return true
            }
            let sinceMagnify = CACurrentMediaTime() - lastMagnifyEventTime
            if sinceMagnify < 0.6 { return true }  // grace after a pinch/commit
            return event.momentumPhase != [] && sinceMagnify < 1.5  // post-pinch inertia
        }
        spacer.shouldBlockScroll = block
        scrollView.shouldBlockScroll = block

        // Redraw on EVERY scroll (incl. momentum / rubber-band) - the scroll itself paces the renderer.
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        // A user-initiated live scroll detaches the "stick to bottom" pin.
        NotificationCenter.default.addObserver(
            self, selector: #selector(userWillScroll),
            name: NSScrollView.willStartLiveScrollNotification, object: scrollView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(userDidEndScroll),
            name: NSScrollView.didEndLiveScrollNotification, object: scrollView
        )
    }

    @objc private func userWillScroll() {
        stickToBottom = false
        liveScrollInputActive = true
        updateFeedInteractionState()
    }

    @objc private func userDidEndScroll() {
        liveScrollInputActive = false
        updateFeedInteractionState()
    }

    /// A user-initiated live resize detaches the bottom pin so viewport anchoring can rebase the camera.
    /// Initial layout keeps the one-shot newest policy. The observer is wired in `viewDidMoveToWindow`.
    @objc private func windowWillLiveResize() {
        stickToBottom = false
        liveResizeStartFrame = viewportScreenFrame()
        // ARM the synchronized present for the whole gesture: the renderer then commits, waits until
        // scheduled and presents inside the window's CATransaction (see `MetalGridRenderer.present`).
        // Without this the async present races the layer resize - the previous frame gets stretched to the
        // new size for a beat every tick, which reads as jitter/shimmer while dragging the window edge.
        metalView.presentsWithTransaction = true
        coordinator.liveResizeChanged?(true)
        guard coordinator.canPresentResize else { return }
        coordinator.beginPresentationResize()
    }

    /// Ends a live resize by resolving the final layout and rebasing the scroll once. A resize that did not start
    /// a presentation only clears the synchronized-present flag.
    @objc private func windowDidEndLiveResize() {
        metalView.presentsWithTransaction = false  // back to the cheaper async present once settled
        coordinator.liveResizeChanged?(false)
        guard coordinator.presentationResizeActive else {
            applyResolvedGridProfileAfterLiveResizeFallback()
            return
        }
        // Width and corner changes scale the fixed-column grid and animate to the resize anchor. A pure vertical
        // change keeps the live counter-scrolled position and settles without animation.
        let widthChanged = abs(viewportScreenFrame().width - liveResizeStartFrame.width) > 0.5
        let finalScrollY =
            widthChanged
            ? coordinator.windowResizeReleaseScrollY()
            : coordinator.presentationStartScrollY - coordinator.presentationVerticalShift
        stickToBottom = false
        applyContentSize(coordinator.contentSize())
        let maxScrollY = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
        let settledY = min(max(0, finalScrollY), maxScrollY)
        // The detent fly-into-place only applies to a width reflow; a pure vertical resize settles instantly.
        let animating = widthChanged && coordinator.beginResizeSettle(targetScrollY: settledY)
        coordinator.endPresentationResize()
        if abs(settledY - scrollView.contentView.bounds.origin.y) > 0.5 {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: settledY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if animating { resizeSettleStart = CACurrentMediaTime() }
        let finalFrame = viewportScreenFrame()
        let profileOldFrame = liveResizeStartFrame == .zero ? lastViewportScreenFrame : liveResizeStartFrame
        lastViewportScreenFrame = finalFrame
        liveResizeStartFrame = .zero
        _ = applyResolvedGridProfileIfNeeded(oldFrame: profileOldFrame, newFrame: finalFrame)
        requestFrame()
    }

    private func applyResolvedGridProfileAfterLiveResizeFallback() {
        let oldFrame = liveResizeStartFrame == .zero ? lastViewportScreenFrame : liveResizeStartFrame
        let newFrame = viewportScreenFrame()
        liveResizeStartFrame = .zero
        _ = applyResolvedGridProfileIfNeeded(oldFrame: oldFrame, newFrame: newFrame)
    }

    // MARK: - Live focus-row pinch zoom (engine-owned GridZoomTransaction)

    /// A trackpad pinch drives an engine-owned `GridZoomTransaction`: the item under the cursor is the anchor,
    /// the focus row keeps its photos while the level glides, and release snaps to the nearest level.
    ///
    /// The transaction is single-section only (see `GridZoomTransaction`). Production uses one physical layout
    /// section by design (the flattened photo wall), so the pinch drives the transaction normally. If a grid
    /// ever had multiple physical sections, `beginLiveZoom` would start no transaction and the pinch would stay
    /// inert here (zoom via the +/- controls instead) - a safety fallback, not a production path.
    private func handleMagnify(_ event: NSEvent) {
        switch event.phase {
        case .began:
            // A quick re-pinch must not strand the previous frozen plan on screen.
            finishInFlightPinchSettle()
            finishInFlightGridPresentationForGestureStart()
            let cursorContent = cursorContentPoint(for: event)
            let viewportPoint = CGPoint(x: cursorContent.x, y: cursorContent.y - scrollView.contentView.bounds.origin.y)
            coordinator.beginLiveZoom(cursorContentPoint: cursorContent, viewportPoint: viewportPoint)
            guard coordinator.isZoomingLive else { return }
            stickToBottom = false
            pinchActive = true
            updateFeedInteractionState()
            pinchSettling = false
            pinchBaseLevel = coordinator.level
            pinchCumulativeMagnification = 0
            // Live-pinch scrub driver: routing is decided on the first resolved direction (the eligible band is
            // captured now); the driver is begun then. Tuning mirrors the central surface.
            pinchMode = .undecided
            pinchBuiltSegment = nil
            pinchChainBand = coordinator.eligiblePinchChainBand()
            pinchDriver = PinchLiveZoomDriver(tuning: .init(from: coordinator.gridTransition.tuning))
            pinchPrevMagnifyTime = CACurrentMediaTime()
            scrollLockOrigin = scrollView.contentView.bounds.origin  // freeze scroll for the gesture
            lastMagnifyEventTime = CACurrentMediaTime()  // arm the post-pinch scroll grace
        case .changed, .mayBegin:
            guard pinchActive else { return }
            lastMagnifyEventTime = CACurrentMediaTime()
            pinchCumulativeMagnification += event.magnification
            let pos =
                CGFloat(pinchBaseLevel)
                - GridPinchDensityPolicy.continuousLevelDelta(magnification: pinchCumulativeMagnification)
            driveLivePinch(continuousLevel: pos)
            requestFrame()
        case .ended:
            guard pinchActive else { return }
            if event.magnification != 0 { pinchCumulativeMagnification += event.magnification }
            endLivePinch(cancelled: false)
        case .cancelled:
            guard pinchActive else { return }
            endLivePinch(cancelled: true)
        default:
            break
        }
    }

    /// Route a live pinch sample. On the first resolved direction, choose the mode: an in-band adjacent step
    /// Uses the lattice for a continuous multi-level scrub; otherwise uses the
    /// `GridZoomTransaction` reflow (`transactionReflow`). Once decided, the mode holds for the gesture.
    private func driveLivePinch(continuousLevel pos: CGFloat) {
        let now = CACurrentMediaTime()
        let dt = pinchPrevMagnifyTime == 0 ? 1.0 / 60.0 : max(0, now - pinchPrevMagnifyTime)
        pinchPrevMagnifyTime = now
        switch pinchMode {
        case .reflow:
            coordinator.updateLiveZoom(continuousLevel: pos)
        case .overviewDissolve:
            driveOverviewDissolve(continuousLevel: pos)
        case .lattice:
            _ = applyLatticeSegment(pinchDriver.update(continuousLevel: Double(pos), dt: dt))
            if pinchMode == .reflow { coordinator.updateLiveZoom(continuousLevel: pos) }
        case .undecided:
            let start = pinchBaseLevel
            guard abs(Double(pos) - Double(start)) >= pinchDriver.tuning.directionResolveQ else { return }
            switch GridPinchRoutePolicy.candidate(
                startLevel: start,
                direction: pos < CGFloat(start) ? -1 : 1,
                chainBand: pinchChainBand,
                engine: coordinator.engine
            ) {
            case .lattice:
                pinchMode = .lattice  // The eligible step starts a continuous chain.
                pinchDriver.begin(startLevel: start, chainLo: pinchChainBand.lo, chainHi: pinchChainBand.hi)
                _ = applyLatticeSegment(pinchDriver.update(continuousLevel: Double(pos), dt: dt))
            case .overviewDissolve(let target):
                if coordinator.beginOverviewDissolve(
                    sourceLevel: start, targetLevel: target, viewportSize: metalView.bounds.size)
                {
                    pinchMode = .overviewDissolve  // Overview boundaries use two-layer compositing.
                    pinchOverviewSource = start
                    pinchOverviewTarget = target
                    driveOverviewDissolve(continuousLevel: pos)
                } else {
                    pinchMode = .reflow
                    coordinator.updateLiveZoom(continuousLevel: pos)
                }
            case .reflow:
                pinchMode = .reflow  // Out-of-band gestures use transaction reflow.
                coordinator.updateLiveZoom(continuousLevel: pos)
            }
        }
    }

    /// Apply one lattice sample: (re)build the segment plan when the active interval changes (each detent
    /// crossing - seam-continuous), then scrub it to `segmentQ`.
    @discardableResult
    private func applyLatticeSegment(_ out: PinchLiveZoomDriver.Update) -> Bool {
        guard out.hasSegment else { return false }  // Keep the start detent inside the dead band.
        let seg = (out.segmentSource, out.segmentTarget)
        if pinchBuiltSegment == nil || pinchBuiltSegment! != seg {
            if coordinator.tryBuildPinchSegment(
                source: out.segmentSource, target: out.segmentTarget, viewportSize: metalView.bounds.size)
            {
                pinchBuiltSegment = seg
            } else {
                coordinator.abortPinchPlan()  // tear down any active plan (no stranded frozen frame)
                pinchMode = .reflow
                pinchBuiltSegment = nil  // Fall back for an ineligible segment.
                return false
            }
        }
        coordinator.setPinchProgress(out.segmentQ)
        return true
    }

    /// Settles the active gesture to its nearest valid level.
    private func endLivePinch(cancelled: Bool) {
        pinchActive = false
        updateFeedInteractionState()
        switch pinchMode {
        case .lattice:
            pinchDriver.release(cancelled: cancelled)
            pinchSettling = true
            pinchAdvancePrevTime = 0  // fresh dt for the first settle tick
            lastMagnifyEventTime = CACurrentMediaTime()
            requestFrame()
        case .reflow:
            if coordinator.liveZoomLevel < 0 {
                // Spring over-zoom back to level 0, then commit without a snap.
                pinchReflowSettleFrom = coordinator.liveZoomLevel
                pinchReflowSettleStart = CACurrentMediaTime()
                pinchSettling = true
                lastMagnifyEventTime = CACurrentMediaTime()
                requestFrame()
            } else {
                finishLiveZoom(target: cancelled ? pinchBaseLevel : Int(coordinator.liveZoomLevel.rounded()))
            }
        case .overviewDissolve:
            // Settle the dissolve to the nearer endpoint over a short linear ramp.
            pinchOverviewSettleFrom = pinchOverviewQ
            pinchOverviewSettleTo = (!cancelled && pinchOverviewQ >= 0.5) ? 1.0 : 0.0
            pinchOverviewSettleStart = CACurrentMediaTime()
            pinchSettling = true
            lastMagnifyEventTime = CACurrentMediaTime()
            requestFrame()
        case .undecided:
            if !beginShortPinchStep(cancelled: cancelled) {
                finishLiveZoom(target: pinchBaseLevel)  // Keep the start level without directional input.
            }
        }
    }

    /// A very short directional pinch may never clear the live-scrub dead-band, but Apple Photos still treats it
    /// like a normal adjacent zoom command. Use the gesture direction to seed one segment and let it complete at
    /// the click speed; no hard snap, and no need to lift/re-pinch.
    private func beginShortPinchStep(cancelled: Bool) -> Bool {
        guard !cancelled, abs(pinchCumulativeMagnification) > 1e-6 else { return false }
        let direction = pinchCumulativeMagnification > 0 ? -1 : 1  // positive magnification = pinch-in = lower level

        switch GridPinchRoutePolicy.candidate(
            startLevel: pinchBaseLevel, direction: direction, chainBand: pinchChainBand, engine: coordinator.engine
        ) {
        case .lattice:
            pinchMode = .lattice
            pinchDriver.begin(startLevel: pinchBaseLevel, chainLo: pinchChainBand.lo, chainHi: pinchChainBand.hi)
            let out = pinchDriver.releaseTowardAdjacent(direction: direction)
            guard applyLatticeSegment(out) else { return false }
            pinchSettling = true
            pinchAdvancePrevTime = 0
            lastMagnifyEventTime = CACurrentMediaTime()
            requestFrame()
            return true
        case .overviewDissolve(let target):
            guard
                coordinator.beginOverviewDissolve(
                    sourceLevel: pinchBaseLevel, targetLevel: target, viewportSize: metalView.bounds.size)
            else { return false }
            pinchMode = .overviewDissolve
            pinchOverviewSource = pinchBaseLevel
            pinchOverviewTarget = target
            pinchOverviewQ = 0
            coordinator.setOverviewDissolveProgress(0)
            pinchOverviewSettleFrom = 0
            pinchOverviewSettleTo = 1
            pinchOverviewSettleStart = CACurrentMediaTime()
            pinchSettling = true
            lastMagnifyEventTime = CACurrentMediaTime()
            requestFrame()
            return true
        case .reflow:
            return false
        }
    }

    /// If a previous lattice pinch is still running its post-release settle (the settle spans multiple display
    /// ticks), a new pinch's `.began` could leave an active plan frozen on screen. Complete the in-flight
    /// settle and commit its chosen detent before the new gesture starts.
    private func finishInFlightPinchSettle() {
        guard pinchSettling else { return }
        if pinchMode == .overviewDissolve {
            commitOverviewDissolve()
            return
        }  // Complete the dissolve.
        if pinchMode == .reflow {  // over-zoom spring-back in flight
            pinchSettling = false
            finishLiveZoom(target: 0)
            pinchMode = .undecided
            return
        }
        pinchDriver.advance(dt: 10)  // jump the velocity-aware ramp straight to its settle detent
        if pinchDriver.isCommitted { commitLivePinch() }
    }

    /// A new pinch must capture cursor/anchor/layout from one committed geometry state. Sidebar and bridge
    /// presentations are visual-only in-flight states; finish them before the next `GridZoomTransaction` begins.
    private func finishInFlightGridPresentationForGestureStart() {
        var didFinishPresentation = false
        if coordinator.isSidebarResizing {
            let (settleScroll, _) = coordinator.endSidebarResize()
            stickToBottom = false
            applyContentSize(coordinator.contentSize())
            let maxScrollY = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
            let settledY = min(max(0, settleScroll), maxScrollY)
            if abs(settledY - scrollView.contentView.bounds.origin.y) > 0.5 {
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: settledY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            didFinishPresentation = true
        }
        if coordinator.isResizeSettling {
            coordinator.endResizeSettle()
            didFinishPresentation = true
        }
        if coordinator.isCommitBridging {
            coordinator.endCommitBridge()
            didFinishPresentation = true
        }
        guard didFinishPresentation else { return }
        lastViewportScreenFrame = viewportScreenFrame()
        requestFrame()
    }

    /// Advance the post-release settle on the display tick; push the new segmentQ into the plan; commit the
    /// chain's final detent on a terminal state.
    private func advanceLivePinch() {
        let now = CACurrentMediaTime()
        let dt = pinchAdvancePrevTime == 0 ? 1.0 / 60.0 : max(0, now - pinchAdvancePrevTime)
        pinchAdvancePrevTime = now
        pinchDriver.advance(dt: dt)
        coordinator.setPinchProgress(pinchDriver.segmentQ)
        requestFrame()
        if pinchDriver.isCommitted { commitLivePinch() }
    }

    /// The settle reached a terminal state. Commit the chain to its final detent: apply that detent's anchored
    /// scroll (a no-op when it's the gesture-start detent). The settled frame matches the plan's final-detent
    /// endpoint exactly - no hard snap, no flash.
    private func commitLivePinch() {
        pinchSettling = false
        let previousLevel = coordinator.level
        let anchoredY = coordinator.commitPinchChain(
            toLevel: pinchDriver.finalLevel, viewportSize: metalView.bounds.size)
        let clipH = scrollView.contentView.bounds.height
        let content = coordinator.contentSize()
        let committedY = min(max(0, anchoredY), max(0, content.height - clipH))
        lastMagnifyEventTime = CACurrentMediaTime()  // arm the post-commit scroll grace
        scrollLockOrigin = CGPoint(x: 0, y: committedY)
        applyContentSize(content)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: committedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        // Edge/corner clamp: if the anchored scroll was out of bounds, slide there instead of snapping.
        coordinator.beginScrollRebase(fromY: anchoredY, toY: committedY)
        coordinator.logPostCommitAnchor()
        pinchMode = .undecided
        pinchBuiltSegment = nil
        pinchAdvancePrevTime = 0
        pinchDriver.reset()
        commitLevelToBinding(previousLevel: previousLevel)  // sync the SwiftUI level binding (+ arm echo guard)
        requestFrame()
    }

    /// Advance the reflow over-zoom spring-back: ramp the live VISUAL level from the released over-zoom value
    /// back to 0 (smoothstep), then commit at level 0. The grid elastically returns to the largest detent with
    /// no hard snap; the commit at 0 is seamless because there the live frame equals the settled frame.
    private func advanceReflowOverZoomSettle() {
        let elapsed = CACurrentMediaTime() - pinchReflowSettleStart
        let f = pinchReflowSettleDuration > 0 ? min(1, elapsed / pinchReflowSettleDuration) : 1
        let eased = f * f * (3 - 2 * f)  // smoothstep
        coordinator.setLiveVisualLevel(pinchReflowSettleFrom * CGFloat(1 - eased))  // Ends at level 0.
        requestFrame()
        if f >= 1 {
            pinchSettling = false
            finishLiveZoom(target: 0)  // commit at the largest detent
            pinchMode = .undecided
        }
    }

    // MARK: - Live overview layer dissolve (offscreen two-layer cross-dissolve)

    /// Map the pinch magnitude straight to dissolve progress (q=0 at the source level, q=1 at the adjacent
    /// overview level). One boundary step - no detent hysteresis / chaining.
    private func driveOverviewDissolve(continuousLevel pos: CGFloat) {
        let s = CGFloat(pinchOverviewSource)
        let t = CGFloat(pinchOverviewTarget)
        let raw = t > s ? (pos - s) : (s - pos)
        pinchOverviewQ = Double(min(1, max(0, raw)))
        coordinator.setOverviewDissolveProgress(pinchOverviewQ)
    }

    /// Advance the post-release linear settle; commit on completion.
    private func advanceOverviewDissolveSettle() {
        let elapsed = CACurrentMediaTime() - pinchOverviewSettleStart
        let f = pinchOverviewSettleDuration > 0 ? min(1, elapsed / pinchOverviewSettleDuration) : 1
        pinchOverviewQ = pinchOverviewSettleFrom + (pinchOverviewSettleTo - pinchOverviewSettleFrom) * f
        coordinator.setOverviewDissolveProgress(pinchOverviewQ)
        requestFrame()
        if f >= 1 { commitOverviewDissolve() }
    }

    /// Commit the dissolve to its settled endpoint (source if it settled toward 0, else target). The coordinator
    /// adopts the target level/phase + anchored scroll; the settled frame matches the dissolve endpoint exactly.
    private func commitOverviewDissolve() {
        pinchSettling = false
        let previousLevel = coordinator.level
        let toTarget = pinchOverviewSettleTo >= 0.5
        let anchoredY = coordinator.commitOverviewDissolve(toTarget: toTarget, viewportSize: metalView.bounds.size)
        let clipH = scrollView.contentView.bounds.height
        let content = coordinator.contentSize()
        let committedY = min(max(0, anchoredY), max(0, content.height - clipH))
        lastMagnifyEventTime = CACurrentMediaTime()  // arm the post-commit scroll grace
        scrollLockOrigin = CGPoint(x: 0, y: committedY)
        applyContentSize(content)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: committedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        // Edge/corner clamp: if the anchored scroll was out of bounds, slide there instead of snapping.
        coordinator.beginScrollRebase(fromY: anchoredY, toY: committedY)
        coordinator.logPostCommitAnchor()
        pinchMode = .undecided
        pinchOverviewQ = 0
        commitLevelToBinding(previousLevel: previousLevel)  // sync the SwiftUI level binding (+ arm echo guard)
        requestFrame()
    }

    /// Commit the live zoom: rebase scroll from the anchor, then run a short geometry-only BRIDGE that slides
    /// the transaction-final frame to the settled frame (so the column-phase reflow is smooth, not a snap).
    private func finishLiveZoom(target: Int) {
        let previousLevel = coordinator.level
        let clamped = max(0, min(target, coordinator.levelCount - 1))
        let newY = coordinator.beginCommitBridge(finalLevel: clamped)  // rebase + capture tx + set level + start bridge
        let clipH = scrollView.contentView.bounds.height
        let content = coordinator.contentSize()
        let targetY =
            (!stickToBottom && newY != nil)
            ? min(max(0, newY!), max(0, content.height - clipH))
            : scrollView.contentView.bounds.origin.y
        // Set the scroll lock before changing the scroll position. The post-magnify grace window uses it to reject
        // residual scroll events from the pinch.
        lastMagnifyEventTime = CACurrentMediaTime()
        scrollLockOrigin = CGPoint(x: 0, y: targetY)
        coordinator.setCommitBridgeScrollY(targetY)
        bridgeStart = CACurrentMediaTime()
        applyContentSize(content)
        if !stickToBottom, newY != nil {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if !coordinator.isCommitBridging { coordinator.logPostCommitAnchor() }
        requestFrame()
        commitLevelToBinding(previousLevel: previousLevel)
    }

    /// The cursor's current content-space point from a gesture event (fresh, not the stale last
    /// mouse-moved position), clamped into the current viewport so a centroid just outside still anchors
    /// sensibly (falls back to the viewport centre).
    private func cursorContentPoint(for event: NSEvent) -> CGPoint {
        let raw = spacer.convert(event.locationInWindow, from: nil)
        let inset = coordinator.leadingObstructionInset  // sidebar + (normal-level) gap
        let p = CGPoint(x: raw.x - inset, y: raw.y)  // Render-to-layout X coordinate.
        let origin = scrollView.contentView.bounds.origin
        let vh = scrollView.contentView.bounds.height
        let layoutW = max(1, bounds.width - inset)  // the unobscured layout width
        if p.y >= origin.y, p.y <= origin.y + vh, p.x >= 0, p.x <= layoutW { return p }
        return CGPoint(x: layoutW / 2, y: origin.y + vh / 2)  // layout-space viewport centre
    }

    /// A button-driven level change. The discrete +/- path re-anchors scroll at the viewport centre (the
    /// live trackpad pinch is the continuous path, handled in `handleMagnify`).
    func animateToLevel(_ target: Int) {
        setLevel(target)
    }

    /// Toolbar/keyboard command entry point. Start the renderer-owned click transition immediately,
    /// then mirror its committed level back to SwiftUI; waiting for an updateNSView round-trip could
    /// expose a settled target frame before the transition was armed.
    func performDiscreteZoom(to target: Int) {
        let previousLevel = coordinator.level
        setLevel(target)
        commitLevelToBinding(previousLevel: previousLevel)
    }

    /// Reconcile a SwiftUI `level`-binding value delivered to `updateNSView` against the host's authoritative
    /// `coordinator.level`. Drives `animateToLevel` for a genuine external (+/- / keyboard / programmatic)
    /// change; IGNORES a stale echo of a host-led pinch commit (which would otherwise re-issue a viewport-centre
    /// zoom and jump a different photo under the cursor). Pure decision in `LevelBindingReconciler`.
    func reconcileLevelBinding(_ bindingLevel: Int) {
        let action = LevelBindingReconciler.decide(
            binding: bindingLevel, hostLevel: coordinator.level, staleEcho: pendingLevelEcho)
        switch action {
        case .ignore:
            if pendingLevelEcho != nil, bindingLevel != coordinator.level {  // a suppressed post-commit echo
                GridLevelSyncLog.decision(
                    binding: bindingLevel, hostLevel: coordinator.level, staleEcho: pendingLevelEcho,
                    action: "suppressStaleEcho")
            }
        case .clearLatch:
            pendingLevelEcho = nil
        case .reDrive(let target):
            pendingLevelEcho = nil
            GridLevelSyncLog.decision(
                binding: bindingLevel, hostLevel: coordinator.level, staleEcho: nil, action: "reDrive")
            animateToLevel(target)
        }
    }

    /// Push the settled level to the SwiftUI `level` binding AND arm the stale-echo guard, so a not-yet-
    /// propagated pre-commit binding value cannot re-issue a viewport-centre zoom. The guard is armed only when
    /// the commit actually changed the level - a no-op commit can produce no echo, and arming it would wrongly
    /// swallow the next genuine external change. Call at every host-led commit, in place of `onZoomCommit`.
    private func commitLevelToBinding(previousLevel: Int) {
        if coordinator.level != previousLevel { pendingLevelEcho = previousLevel }
        onZoomCommit?(coordinator.level)
    }

    private func pinToBottom() {
        let maxY = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    deinit {
        // The callback captures this host weakly. Deinit cannot synchronously mutate the main-actor
        // data-source property, and the weak capture makes the orphaned callback a no-op until replacement.
        NotificationCenter.default.removeObserver(self)
    }

    /// True while scroll must be frozen: the live pinch (scrub or settle), the commit bridge, or a short
    /// grace after the magnify.
    private func isScrollBlocking() -> Bool {
        pinchActive || pinchSettling || coordinator.isZoomingLive || coordinator.isCommitBridging
            || coordinator.isScrollRebasing || coordinator.isResizeSettling || coordinator.isSidebarResizing
            || CACurrentMediaTime() - lastMagnifyEventTime < 0.6
    }

    @objc private func scrolled() {
        // SCROLL LOCK backstop: if anything scrolled the grid during a zoom (a leaked scrollWheel / inertia),
        // snap it straight back to the frozen origin so the grid can't drift. Once the zoom is fully done,
        // release the lock and scroll normally.
        if isScrollBlocking(), let locked = scrollLockOrigin {
            let cur = scrollView.contentView.bounds.origin
            if abs(cur.x - locked.x) > 0.5 || abs(cur.y - locked.y) > 0.5 {
                scrollView.contentView.scroll(to: locked)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        } else {
            scrollLockOrigin = nil
        }
        requestFrame()
        onViewportChanged?()
    }

    private func installImageAvailabilityCallback(on source: MetalGridDataSource) {
        if wiredImageAvailabilitySource !== source {
            wiredImageAvailabilitySource?.onImagesAvailable = nil
            wiredImageAvailabilitySource = source
        }
        source.onImagesAvailable = { [weak self] in
            self?.requestFrame()
        }
    }

    private func updateFeedInteractionState() {
        let active = liveScrollInputActive || pinchActive || marqueeInputActive
        guard active != reportedFeedInteractionActive else { return }
        reportedFeedInteractionActive = active
        coordinator.setUserInteractionActive(active, owner: interactionOwner)
    }

    private func ensureDisplayLink() {
        guard window != nil, streamingTick == nil else { return }
        let dl = displayLink(target: self, selector: #selector(step))
        dl.isPaused = true
        dl.add(to: .main, forMode: .common)
        streamingTick = dl
    }

    private func requestFrame() {
        framePump.invalidate()
        wakeDisplayLink()
    }

    private func wakeDisplayLink() {
        guard window != nil, framePump.isActive else { return }
        ensureDisplayLink()
        streamingTick?.isPaused = false
    }

    private func displayLinkHasActiveWork() -> Bool {
        framePump.shouldTick
            || coordinator.isCommitBridging
            || coordinator.isSidebarResizing
            || coordinator.isResizeSettling
            || coordinator.isScrollRebasing
            || coordinator.gridTransition.activeKind == .click
            || coordinator.isOverviewClickDissolving
            || coordinator.hasPendingVisibleThumbnails
            || pendingResolvedGridProfile != nil
            || (pinchMode == .lattice && pinchDriver.isSelfAdvancing)
            || (pinchMode == .overviewDissolve && pinchSettling)
            || (pinchMode == .reflow && pinchSettling)
    }

    private func updateDisplayLinkIdleState() {
        streamingTick?.isPaused = !framePump.isActive || !displayLinkHasActiveWork()
    }

    func updateGridProfileResolver(_ resolver: TimelineGridProfileResolver?) {
        gridProfileResolver = resolver
        if resolver == nil { pendingResolvedGridProfile = nil }
        _ = applyResolvedGridProfileIfNeeded(oldFrame: lastViewportScreenFrame, newFrame: viewportScreenFrame())
    }

    func updateFillOrder(_ newFillOrder: GridFillOrder) {
        guard fillOrder != newFillOrder else { return }
        fillOrder = newFillOrder
        coordinator.setFillOrder(newFillOrder)
        applyContentSize(coordinator.contentSize())
        requestFrame()
    }

    private var canApplyResolvedGridProfile: Bool {
        window != nil
            && !inLiveResize
            && !pinchActive
            && !pinchSettling
            && !coordinator.presentationResizeActive
            && !coordinator.isSidebarResizing
            && !coordinator.isResizeSettling
            && !coordinator.isZoomingLive
            && !coordinator.isCommitBridging
            && !coordinator.isScrollRebasing
            && !coordinator.gridTransition.isActive
            && coordinator.overviewDissolve == nil
    }

    @discardableResult
    private func applyResolvedGridProfileIfNeeded(oldFrame: NSRect, newFrame: NSRect) -> Bool {
        guard let resolver = gridProfileResolver else {
            pendingResolvedGridProfile = nil
            return false
        }
        let frame = newFrame.width > 1 ? newFrame : viewportScreenFrame()
        guard frame.width > 1 else { return false }

        let layoutWidth = coordinator.layoutWidth > 1 ? coordinator.layoutWidth : frame.width
        let viewport = TimelineGridViewport(layoutWidth: layoutWidth, layoutHeight: frame.height)
        let resolved = resolver.profile(for: viewport)
        guard resolved.id != coordinator.gridProfileID else {
            pendingResolvedGridProfile = nil
            return false
        }

        guard canApplyResolvedGridProfile else {
            pendingResolvedGridProfile = resolved
            wakeDisplayLink()
            return false
        }

        let previousLevel = coordinator.level
        let oldScrollY = scrollView.contentView.bounds.origin.y
        let oldMaxScroll = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
        let atOrBelowBottom = stickToBottom || oldScrollY >= oldMaxScroll - 2
        let sourceFrame = oldFrame == .zero ? frame : oldFrame
        guard
            let result = coordinator.applyGridProfile(
                resolved,
                oldFrame: sourceFrame,
                newFrame: frame,
                oldScrollY: oldScrollY,
                wasBottomPinned: atOrBelowBottom
            )
        else {
            pendingResolvedGridProfile = nil
            return false
        }

        pendingResolvedGridProfile = nil
        applyContentSize(coordinator.contentSize())
        if !stickToBottom {
            let maxY = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
            let y = min(max(0, result.newScrollY), maxY)
            scrollLockOrigin = nil
            if abs(y - oldScrollY) > 0.5 {
                let rebasedPoint = CGPoint(x: 0, y: y)
                scrollView.contentView.scroll(to: rebasedPoint)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        commitLevelToBinding(previousLevel: previousLevel)
        requestFrame()
        onViewportChanged?()
        return true
    }

    // Visibility activates the shared pump; attaching to an initially hidden window alone cannot draw.
    // Invalidate the link on detachment to release its retained target.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A manual window resize detaches the bottom-pin (so the camera rebase runs even on a fresh-open grid).
        NotificationCenter.default.removeObserver(self, name: NSWindow.willStartLiveResizeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didEndLiveResizeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillLiveResize),
                name: NSWindow.willStartLiveResizeNotification, object: window)
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidEndLiveResize),
                name: NSWindow.didEndLiveResizeNotification, object: window)
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowVisibilityChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        framePump.setActive(window?.occlusionState.contains(.visible) == true)
        if window != nil {
            ensureDisplayLink()
            requestFrame()
            _ = applyResolvedGridProfileIfNeeded(oldFrame: lastViewportScreenFrame, newFrame: viewportScreenFrame())
        } else {
            liveScrollInputActive = false
            pinchActive = false
            marqueeInputActive = false
            updateFeedInteractionState()
            streamingTick?.invalidate()
            streamingTick = nil
            coordinator.retireLocalDemand()
        }
    }

    @objc private func windowVisibilityChanged() {
        let wasActive = framePump.isActive
        framePump.setActive(window?.occlusionState.contains(.visible) == true)
        if framePump.isActive { requestFrame() }
        if wasActive, !framePump.isActive { coordinator.retireLocalDemand() }
        updateDisplayLinkIdleState()
    }

    @objc func step() {
        guard framePump.isActive else {
            updateDisplayLinkIdleState()
            return
        }
        if coordinator.isCommitBridging { advanceCommitBridge() }
        if coordinator.isSidebarResizing {
            advanceSidebarResize()
        } else {
            sidebarEdgeSource = nil  // a superseded or finished transition leaves no edge source behind
        }
        if coordinator.isResizeSettling { advanceResizeSettle() }
        if coordinator.gridTransition.activeKind == .click { requestFrame() }
        if coordinator.isOverviewClickDissolving { requestFrame() }
        // Live-pinch post-release settle. Gated on lattice mode so the driver never drives the reflow fallback;
        // reset the tick dt whenever it isn't running.
        if pinchMode == .lattice, pinchDriver.isSelfAdvancing { advanceLivePinch() } else { pinchAdvancePrevTime = 0 }
        if pinchMode == .overviewDissolve, pinchSettling { advanceOverviewDissolveSettle() }  // release settle
        if pinchMode == .reflow, pinchSettling { advanceReflowOverZoomSettle() }  // over-zoom spring-back
        if coordinator.isScrollRebasing { requestFrame() }  // edge/corner rebase slide
        if coordinator.hasPendingVisibleThumbnails { requestFrame() }
        _ = applyResolvedGridProfileIfNeeded(oldFrame: lastViewportScreenFrame, newFrame: viewportScreenFrame())
        if framePump.beginTick() {
            metalView.draw()
            framePump.completeTick(coordinator.lastRenderOutcome)
        }
        updateDisplayLinkIdleState()
    }

    /// Advance the post-release commit bridge. End it when geometry settles; scrolling stays locked throughout.
    private func advanceCommitBridge() {
        let t = bridgeDuration > 0 ? min(1, (CACurrentMediaTime() - bridgeStart) / bridgeDuration) : 1
        coordinator.commitBridgeProgress = CGFloat(t)
        requestFrame()
        if t >= 1 {
            coordinator.endCommitBridge()
            requestFrame()
        }
    }

    /// Advance the sidebar open/close transition. Its last frame is the canonical target geometry, so committing
    /// the engine inset cannot produce a second resize; a release morph remains only for future column reflows.
    private func advanceSidebarResize() {
        let arrived = coordinator.advanceSidebarResize(
            elapsed: sidebarClock() - sidebarResizeStart, measuredEdge: sidebarEdgeSource?.edge())
        requestFrame()
        guard arrived else { return }
        sidebarEdgeSource = nil
        let (settleScroll, animating) = coordinator.endSidebarResize()  // commits the inset + bottom-anchored scroll
        coordinator.liveResizeChanged?(false)
        stickToBottom = false
        applyContentSize(coordinator.contentSize())
        let maxScrollY = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
        let settledY = min(max(0, settleScroll), maxScrollY)
        if abs(settledY - scrollView.contentView.bounds.origin.y) > 0.5 {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: settledY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if animating { resizeSettleStart = CACurrentMediaTime() }
        let oldFrame = lastViewportScreenFrame
        let newFrame = viewportScreenFrame()
        lastViewportScreenFrame = newFrame
        _ = applyResolvedGridProfileIfNeeded(oldFrame: oldFrame, newFrame: newFrame)
        requestFrame()
    }

    /// Advance the release-time resize settle: morph the scaled frame into the settled layout. The scroll is
    /// already at its settled value, so when this completes the canonical render matches exactly (no jump).
    private func advanceResizeSettle() {
        let t = resizeSettleDuration > 0 ? min(1, (CACurrentMediaTime() - resizeSettleStart) / resizeSettleDuration) : 1
        coordinator.resizeSettleProgress = CGFloat(t)
        requestFrame()
        if t >= 1 {
            coordinator.endResizeSettle()
            _ = applyResolvedGridProfileIfNeeded(oldFrame: lastViewportScreenFrame, newFrame: viewportScreenFrame())
            requestFrame()
        }
    }

    override func layout() {
        super.layout()
        metalView.frame = bounds
        let newFrame = viewportScreenFrame()
        let old = lastViewportScreenFrame
        // Live resize presentation scales and slides captured slot geometry about the stationary edge.
        // Skip engine resolution and content-size rebasing until `didEndLiveResize`.
        if inLiveResize, coordinator.presentationResizeActive, liveResizeStartFrame != .zero {
            // The presentation scales horizontally and slides vertically. Present synchronously during live
            // resize so the frame follows the window border. The vertical counter-scroll applies only to a height-only drag, where the tiles
            // keep their size. A corner drag also changes width, so the tiles scale and the resize anchor (centre /
            // bottom) already handles the vertical position; adding the slide on top double-counts and snaps back on
            // release (the corner jump). So gate it off whenever the width is changing.
            let widthChanging = abs(newFrame.width - liveResizeStartFrame.width) > 0.5
            coordinator.presentationVerticalShift =
                widthChanging ? 0 : verticalCounterScroll(start: liveResizeStartFrame, current: newFrame)
            metalView.draw()
            lastViewportScreenFrame = newFrame
            return
        }
        if applyResolvedGridProfileIfNeeded(oldFrame: old, newFrame: newFrame) {
            lastViewportScreenFrame = newFrame
            return
        }
        if old != .zero, viewportGeometryChanged(old, newFrame) {
            rebaseForResize(oldFrame: old, newFrame: newFrame)  // window resize / sidebar toggle - NOT zoom
        } else {
            applyContentSize(coordinator.contentSize())  // first layout / move-only (no size change)
        }
        lastViewportScreenFrame = newFrame
    }

    /// The vertical counter-scroll (viewport pixels, y-down) for a window vertical resize: the dragging edge clips
    /// the grid, and the OPPOSITE edge gives up a fraction `f` of the height change - Apple's shared-loss slide
    /// (the grid drifts toward the dragging edge instead of the dragging edge guillotining it). 0 when the height
    /// did not change (pure-horizontal). `f` ≈ ⅓ (the opposite edge's share; tunable).
    private func verticalCounterScroll(start: NSRect, current: NSRect) -> CGFloat {
        let dH = start.height - current.height  // shrink positive (screen y-up height == viewport height)
        guard abs(dH) > 0.5 else { return 0 }
        // A bottom-edge drag keeps maxY fixed. A top-edge drag keeps minY fixed.
        let topEdgeDrag = abs(current.maxY - start.maxY) > abs(current.minY - start.minY)
        let rawShift = MetalGridCoordinator.verticalCounterScrollShift(
            dH: dH, topEdgeDrag: topEdgeDrag, fraction: 1.0 / 3.0)
        // Clamp to the content bounds: at the very top/bottom of the library the dragging edge CANNOT pull empty
        // space into view, so the reveal redirects to the opposite edge - the effective scroll clamps to
        // [0, maxScroll] at the NEW height. (At the bottom, growing pins the last row and reveals older rows at the
        // top instead of opening a void below; symmetric at the top.)
        let startScrollY = coordinator.presentationStartScrollY
        let maxScroll = max(0, spacer.frame.height - current.height)
        let clampedScroll = min(max(0, startScrollY - rawShift), maxScroll)
        return startScrollY - clampedScroll
    }

    /// The grid layout viewport's frame in screen coordinates (y-up): `maxY` = top edge, `minY` = bottom edge. The
    /// MTKView renders full-width under the sidebar, but the engine's settled layout is only the unobscured
    /// width to the right of `coordinator.leadingObstructionInset`. Resize rebase must therefore use this
    /// layout-space frame, never the full render frame, or the sidebar animation changes slotSide without a
    /// coherent scroll rebase. Falls back to local bounds before the view has a window.
    private func viewportScreenFrame() -> NSRect {
        let full: NSRect
        if let window {
            full = window.convertToScreen(convert(bounds, to: nil))
        } else {
            full = bounds
        }
        let inset = coordinator.leadingObstructionInset
        return NSRect(x: full.minX + inset, y: full.minY, width: max(1, full.width - inset), height: full.height)
    }

    private func viewportGeometryChanged(_ old: NSRect, _ new: NSRect) -> Bool {
        abs(old.width - new.width) > 0.5 || abs(old.height - new.height) > 0.5
    }

    /// SwiftUI safe-area changes from the floating sidebar do not always arrive as an AppKit `layout()` pass.
    /// Treat the inset change itself as a layout-width resize so the scroll camera rebases during the sidebar
    /// animation instead of letting content-size changes accumulate and snap on the next scroll/resize tick.
    private func applyLeadingInsetChange(from oldValue: CGFloat) {
        guard abs(eventLeadingInset - oldValue) > 0.5 else { return }
        let oldFrame = lastViewportScreenFrame
        // Sidebar open and close are left-edge resizes. Snapshot at the old inset, resolve the canonical target,
        // and interpolate between the two states.
        // over the slide duration. Instant fallback when the presentation can't run
        // (mid window live-resize, no window, zoom in flight, first layout).
        if window != nil, !inLiveResize, oldFrame != .zero,
            coordinator.beginSidebarResize(fromInset: oldValue, toInset: eventLeadingInset)
        {
            sidebarResizeStart = sidebarClock()
            sidebarEdgeSource = SplitViewSidebarEdgeSource(hostedIn: self)
            coordinator.liveResizeChanged?(true)
            requestFrame()
            return
        }
        coordinator.sidebarObstructionInset = eventLeadingInset
        guard oldFrame != .zero else { return }
        let newFrame = viewportScreenFrame()
        if viewportGeometryChanged(oldFrame, newFrame) {
            rebaseForResize(oldFrame: oldFrame, newFrame: newFrame)
        } else {
            applyContentSize(coordinator.contentSize())
        }
        lastViewportScreenFrame = newFrame
        _ = applyResolvedGridProfileIfNeeded(oldFrame: oldFrame, newFrame: newFrame)
    }

    /// Recompute content size after a window or sidebar resize and rebase the scroll through the engine.
    /// The stationary edge holds the anchor, and the moving edge clips or reveals content. Bottom-pinned
    /// views remain pinned.
    private func rebaseForResize(oldFrame: NSRect, newFrame: NSRect) {
        let placingInitial = pendingInitialViewport != .preserve
        let oldScrollY = scrollView.contentView.bounds.origin.y
        // At or beyond the newest edge, pin to the new content bottom. This avoids resolving an anchor in
        // trailing empty space after a pinch and prevents a jump into older content.
        let oldMaxScroll = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
        let atOrBelowBottom = stickToBottom || oldScrollY >= oldMaxScroll - 2
        let result = coordinator.rebaseForViewportChange(
            oldFrame: oldFrame, newFrame: newFrame,
            oldScrollY: oldScrollY, wasBottomPinned: atOrBelowBottom)
        applyContentSize(coordinator.contentSize())  // new content height (new width); consumes a pending policy
        if placingInitial, pendingInitialViewport == .preserve { return }  // Keep the initial placement.
        guard !stickToBottom, let r = result else { return }  // Sticky placement is already bottom-pinned.
        let maxY = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
        let y = min(max(0, r.newScrollY), maxY)
        scrollLockOrigin = nil  // a resize must NOT restore a pre-resize origin
        if abs(y - oldScrollY) > 0.5 {  // skip a no-op scroll (e.g. top-anchored width change)
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        requestFrame()  // first frame after resize uses the rebased scrollY
    }

    /// Set the document spacer to the current content height (width tracks the clip, no h-scroll). This is also
    /// the single consume point for a pending `.newest` initial-viewport policy. Placement waits until the
    /// spacer frame and layout geometry are valid.
    private func applyContentSize(_ size: CGSize) {
        let width = scrollView.contentView.bounds.width
        // If geometry is not valid, install nothing and leave the pending policy unchanged.
        guard width > 1, size.height > 0 else { return }
        let newFrame = NSRect(x: 0, y: 0, width: width, height: size.height)
        if spacer.frame != newFrame { spacer.frame = newFrame }  // spacer/document frame installed first
        let clipH = scrollView.contentView.bounds.height
        if pendingInitialViewport != .preserve, window != nil, clipH > 0 {
            // Consume the one-shot placement against the now-valid geometry (real window, real content + clip
            // height). After this the policy is cleared and bottom-pinning stays off.
            placeForInitialViewport(pendingInitialViewport, clipHeight: clipH)
            pendingInitialViewport = .preserve
        } else if stickToBottom {
            pinToBottom()  // launch / sticky open: stay at newest (bottom) until the user scrolls
        }
        requestFrame()
        onViewportChanged?()
    }

    /// Consume a pending initial-viewport policy once at the newest end (`.newest`) or at a remembered photo
    /// anchor (`.restore`). This does not re-arm bottom-pinning, so the user's first manual scroll is honoured
    /// and never pulled back. `.restore` re-resolves the anchored photo's position in the current layout (so it
    /// is exact across any zoom/width/phase change while away); if that photo is gone (e.g. trashed meanwhile) it
    /// falls back to the newest end.
    private func placeForInitialViewport(_ policy: GridInitialViewport, clipHeight: CGFloat) {
        let maxY = max(0, spacer.frame.height - clipHeight)
        let targetY: CGFloat
        switch policy {
        case .newest:
            targetY = maxY
        case .oldest:
            targetY = 0
        case .restore(let anchor):
            if let index = coordinator.flatIndex(forUID: anchor.itemID),
                let rect = coordinator.cellContentRect(forFlatIndex: index)
            {
                targetY = min(max(0, rect.minY - anchor.topOffset), maxY)
            } else {
                targetY = maxY  // If the anchor is gone, use the newest edge.
            }
        case .preserve:
            return
        }
        stickToBottom = false
        scrollLockOrigin = nil  // no stale zoom lock may override the placement
        lastMagnifyEventTime = 0  // clear any post-magnify scroll-suppression grace
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Arm a one-shot initial-viewport policy: reset to the canonical bottom-right phase (so the content height
    /// matches what a remembered offset was captured against) and mark the policy pending. The actual placement
    /// is deferred to `applyContentSize` (called below and on every subsequent layout) once the geometry is
    /// valid - never an immediate scroll. Used for sidebar route switches and for a freshly (re)created host.
    func requestInitialViewport(_ policy: GridInitialViewport) {
        guard policy != .preserve else { return }
        pendingInitialViewport = policy
        coordinator.resetCommittedPhase()
        applyContentSize(coordinator.contentSize())  // consume now if geometry is valid; else it stays pending
    }

    /// Returns a layout-independent anchor for restoring the current route.
    func currentScrollAnchor() -> GridScrollAnchor<PhotoUID>? {
        let originY = scrollView.contentView.bounds.origin.y
        guard
            let top = GridScrollAnchorPolicy.anchor(
                among: coordinator.visibleCells(), visibleTop: originY + topBarInset,
                visibleBottom: originY + scrollView.contentView.bounds.height, frame: \.rect),
            let uid = coordinator.uid(atFlatIndex: top.flatIndex)
        else { return nil }
        return GridScrollAnchor(itemID: uid, topOffset: top.rect.minY - originY)
    }

    // MARK: - Public controls

    /// Change zoom level while holding an explicit anchor point under the same viewport position (zoom directed
    /// toward that point - the Apple rule). `anchorContentPoint` is the cursor's content point for a trackpad
    /// pinch; for +/- it is nil and the viewport centre is used. The top-visible item is not used. Pinned-to-bottom
    /// (newest) stays pinned.
    func setLevel(_ newLevel: Int, anchorContentPoint: CGPoint? = nil) {
        guard newLevel != coordinator.level else { return }
        let vh = scrollView.contentView.bounds.height
        let origin = scrollView.contentView.bounds.origin
        // +/- anchors at the grid viewport centre (never the toolbar-button mouse point, a stale hover, or the
        // top). The pinch path supplies an explicit cursor point instead.
        // Layout-space viewport centre (the engine works in layout space; never add the inset back here - the
        // render translation happens once at the coordinator's draw chokepoint).
        let anchorPoint =
            anchorContentPoint
            ?? CGPoint(x: max(1, bounds.width - coordinator.leadingObstructionInset) / 2, y: origin.y + vh / 2)
        let viewportPoint = CGPoint(x: anchorPoint.x, y: anchorPoint.y - origin.y)
        let trigger: GridZoomTrigger = newLevel < coordinator.level ? .toolbarPlus : .toolbarMinus  // plus = zoom in
        // Try the single-lattice transition first, including when the grid is freshly bottom-pinned
        // (`stickToBottom`). Otherwise the early-return below would bypass it. It commits the settled target
        // Apply the transition's anchored scroll and skip the fallback snap.
        if let tY = coordinator.tryBeginClickTransition(
            toLevel: newLevel, anchorContentPoint: anchorPoint,
            viewportPoint: viewportPoint, viewportSize: metalView.bounds.size)
        {
            stickToBottom = false  // an anchored zoom ends bottom-pinning (like a scroll)
            applyContentSize(coordinator.contentSize())
            let maxY = max(0, spacer.frame.height - vh)
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: min(max(0, tY), maxY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            coordinator.logPostCommitAnchor()
            requestFrame()
            return
        }
        if let tY = coordinator.tryBeginClickOverviewDissolve(
            toLevel: newLevel, anchorContentPoint: anchorPoint,
            viewportPoint: viewportPoint, viewportSize: metalView.bounds.size)
        {
            stickToBottom = false
            applyContentSize(coordinator.contentSize())
            let maxY = max(0, spacer.frame.height - vh)
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: min(max(0, tY), maxY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            coordinator.logPostCommitAnchor()
            requestFrame()
            return
        }
        if stickToBottom {
            coordinator.level = newLevel
            applyContentSize(coordinator.contentSize())  // pins to bottom (newest)
            requestFrame()
            return
        }
        // Latches the committed column phase so the settled grid keeps the anchor's column (no fly).
        let newY = coordinator.settleScrollOffsetY(
            toLevel: newLevel, anchorContentPoint: anchorPoint, viewportPoint: viewportPoint, trigger: trigger)
        applyContentSize(coordinator.contentSize())
        if let newY {
            let maxY = max(0, spacer.frame.height - vh)
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: min(max(0, newY), maxY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        coordinator.logPostCommitAnchor()
        requestFrame()
    }

    /// A photo's cell frame in window content coordinates (top-left origin), or nil if it isn't visible -
    /// used by the shared-element zoom transition (window-coordinate frame of a visible cell).
    func windowFrame(forUID uid: PhotoUID) -> CGRect? {
        guard let win = window, let contentRect = coordinator.cellContentRect(forUID: uid) else { return nil }
        let origin = scrollView.contentView.bounds.origin
        // Translate the engine-space rectangle into the rendered viewport.
        let vp = CGRect(
            x: contentRect.minX - origin.x + coordinator.leadingObstructionInset, y: contentRect.minY - origin.y,
            width: contentRect.width, height: contentRect.height)
        guard CGRect(origin: .zero, size: metalView.bounds.size).intersects(vp) else { return nil }
        // The metal view is not flipped (y-up); our viewport rect is top-left origin (y-down).
        let localYUp = CGRect(x: vp.minX, y: metalView.bounds.height - vp.maxY, width: vp.width, height: vp.height)
        let inWindow = metalView.convert(localYUp, to: nil)  // window coords, bottom-left origin
        let contentH = win.contentView?.bounds.height ?? win.frame.height
        return CGRect(x: inWindow.minX, y: contentH - inWindow.maxY, width: inWindow.width, height: inWindow.height)
    }

    /// Install a new data source. For an incremental update, pass `.preserve` to keep the current scroll
    /// position. For a sidebar route switch, pass `.newest` to arm one-shot placement consumed by
    /// `applyContentSize` after geometry is valid. It does not scroll immediately or arm sticky bottom-pinning.
    func setDataSource(
        _ source: MetalGridDataSource, initialViewport: GridInitialViewport = .preserve,
        preservingColumnPhase: Bool = false
    ) {
        installImageAvailabilityCallback(on: source)
        if initialViewport != .preserve {
            pendingInitialViewport = initialViewport
            if !preservingColumnPhase {
                coordinator.resetCommittedPhase()  // canonical bottom-right phase, BEFORE the size callback
            }
        }
        coordinator.setUserInteractionActive(false, owner: interactionOwner)
        // Rebuild before the size callback.
        coordinator.setDataSource(source, preservingColumnPhase: preservingColumnPhase)
        reportedFeedInteractionActive = false
        updateFeedInteractionState()
        applyContentSize(coordinator.contentSize())  // pins to bottom when sticky / consumes a pending policy
    }

    /// Scroll to the newest (bottom) and re-arm the bottom pin. Resets the camera to the canonical bottom-right
    /// phase so the newest view always has the newest item in the corner (no trailing black at the bottom-right).
    func scrollToBottom() {
        stickToBottom = true
        coordinator.resetCommittedPhase()
        applyContentSize(coordinator.contentSize())  // resize for the canonical phase, then pin to bottom
    }

    /// Scroll a specific photo to vertical center (detaches the bottom pin - the user navigated to it).
    func scrollToItem(_ uid: PhotoUID) {
        stickToBottom = false
        guard let rect = coordinator.cellContentRect(forUID: uid) else { return }
        let clipH = scrollView.contentView.bounds.height
        let maxY = max(0, spacer.frame.height - clipH)
        let targetY = min(max(0, rect.midY - clipH / 2), maxY)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        requestFrame()
    }

    /// Scroll a flattened timeline index near the top of the viewport. This is the date-jump primitive for the
    /// overview scrubber: no SwiftUI geometry, no synthetic sections, no custom scroll physics.
    func scrollToFlatIndex(_ index: Int) {
        stickToBottom = false
        guard let rect = coordinator.cellContentRect(forFlatIndex: index) else { return }
        let clipH = scrollView.contentView.bounds.height
        let maxY = max(0, spacer.frame.height - clipH)
        let targetY = min(max(0, rect.minY - 24), maxY)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        requestFrame()
        onViewportChanged?()
    }
}
