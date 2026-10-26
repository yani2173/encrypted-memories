#if canImport(UIKit)
    import CoreGraphics
    import GridCore
    import MediaCacheUIKitAdapter
    import MediaFeedCore
    import Metal
    import MetalGridComposeCore
    import MetalGridTextureCore
    import MetalGridTextureUIKitAdapter
    import MetalRenderingCore
    import os
    import PhotosCore
    import SwiftUI
    import TimelineCore
    import TimelineUIKitAdapter
    import UIKit

    /// SwiftUI bridge for the first real iOS/iPadOS timeline grid host.
    ///
    /// This is intentionally thin: UIKit owns the scroll surface and drawable, while GridCore, MediaFeedCore,
    /// MetalGridTextureCore, and MetalRenderingCore still own layout, decoded thumbnails, residency, and drawing.
    public struct UIKitTimelineGrid: UIViewRepresentable {
        private let items: [PhotoItem]
        /// A monotonic content identity supplied by the owning projection. When present, selection and chrome
        /// updates avoid re-comparing or re-mapping the complete library while preserving a full fallback for
        /// collection surfaces that do not yet expose a revision.
        private let contentRevision: UInt64?
        private let thumbnailFeed: UIKitThumbnailFeed
        private let metadataProvider: (any PhotoMetadataProvider)?
        private let level: Int?
        private let gridProfile: GridLevelProfile?
        private let fillOrder: GridFillOrder
        private let initialViewportPlacement: TimelineInitialViewportPlacement
        private let displayMode: TileContentDisplayMode
        private let selectionMode: Bool
        private let selectedUIDs: Set<PhotoUID>
        /// Upload badges of pending photos and "Nicht gesichert" badges in the trash.
        private let uploadBadges: PendingUploadBadges
        /// Whether this grid's surface is the active one (its tab is selected). When false the host stops its
        /// display link and cancels ahead-warm so a hidden grid never competes with menus/transitions on screen;
        /// defaults to true so a grid that is always visible (e.g. a pushed collection detail) behaves as before.
        private let isActive: Bool
        /// A monotonically-bumped signal from the shell: whenever it changes, the grid scrolls to the newest
        /// photos. Drives the active Fotos-tab retap gesture that jumps to the newest photos without leaking scroll math
        /// out of the host. Compared against a `Coordinator`-remembered last value so a steady stream of identical
        /// update passes is free.
        private let scrollToLatestSignal: Int
        /// Bumped after a bounded top-leading projection settles. The host applies this after configuring the new
        /// item set, so sparse results cannot inherit a stale full-library offset and disappear above the viewport.
        private let scrollToTopSignal: Int
        private let proxy: GridProxy<PhotoUID>?
        private let restoreScrollAnchor: GridScrollAnchor<PhotoUID>?
        private let restoreScrollSignal: Int
        /// Bumped only when the visible projection changes. The host uses it to dissolve the complete grid once,
        /// instead of making filtered items pop into their new topology during unrelated SwiftUI updates.
        private let contentTransitionSignal: Int
        private let prefersReducedMotion: Bool
        private let onFirstContentReady: (() -> Void)?
        private let onVisibleDatesChanged: ((String?) -> Void)?
        private let onOpenPhoto: ((PhotoItem) -> Void)?
        private let onToggleSelection: ((PhotoItem) -> Void)?
        private let onSelectionChanged: ((Set<PhotoUID>) -> Void)?
        private let dragOutProvider: (any OriginalFileProvider)?
        private let onDragOutFailed: ((DragOutFailureKind) -> Void)?
        private let contextMenuActions: (([PhotoItem]) -> [PhotoContextMenuAction])?
        private let onContextMenuAction: ((PhotoContextMenuAction, [PhotoItem]) -> Void)?

        public init(
            items: [PhotoItem],
            contentRevision: UInt64? = nil,
            thumbnailFeed: UIKitThumbnailFeed,
            metadataProvider: (any PhotoMetadataProvider)? = nil,
            level: Int? = nil,
            gridProfile: GridLevelProfile? = nil,
            fillOrder: GridFillOrder = .newestBottomTrailing,
            initialViewportPlacement: TimelineInitialViewportPlacement = .automatic,
            displayMode: TileContentDisplayMode = .squareFillCrop,
            selectionMode: Bool = false,
            selectedUIDs: Set<PhotoUID> = [],
            uploadBadges: PendingUploadBadges = .empty,
            isActive: Bool = true,
            scrollToLatestSignal: Int = 0,
            scrollToTopSignal: Int = 0,
            proxy: GridProxy<PhotoUID>? = nil,
            restoreScrollAnchor: GridScrollAnchor<PhotoUID>? = nil,
            restoreScrollSignal: Int = 0,
            contentTransitionSignal: Int = 0,
            prefersReducedMotion: Bool = false,
            onFirstContentReady: (() -> Void)? = nil,
            onVisibleDatesChanged: ((String?) -> Void)? = nil,
            onOpenPhoto: ((PhotoItem) -> Void)? = nil,
            onToggleSelection: ((PhotoItem) -> Void)? = nil,
            onSelectionChanged: ((Set<PhotoUID>) -> Void)? = nil,
            dragOutProvider: (any OriginalFileProvider)? = nil,
            onDragOutFailed: ((DragOutFailureKind) -> Void)? = nil,
            contextMenuActions: (([PhotoItem]) -> [PhotoContextMenuAction])? = nil,
            onContextMenuAction: ((PhotoContextMenuAction, [PhotoItem]) -> Void)? = nil
        ) {
            self.items = items
            self.contentRevision = contentRevision
            self.thumbnailFeed = thumbnailFeed
            self.metadataProvider = metadataProvider
            self.level = level
            self.gridProfile = gridProfile
            self.fillOrder = fillOrder
            self.initialViewportPlacement = initialViewportPlacement
            self.displayMode = displayMode
            self.selectionMode = selectionMode
            self.selectedUIDs = selectedUIDs
            self.uploadBadges = uploadBadges
            self.isActive = isActive
            self.scrollToLatestSignal = scrollToLatestSignal
            self.scrollToTopSignal = scrollToTopSignal
            self.proxy = proxy
            self.restoreScrollAnchor = restoreScrollAnchor
            self.restoreScrollSignal = restoreScrollSignal
            self.contentTransitionSignal = contentTransitionSignal
            self.prefersReducedMotion = prefersReducedMotion
            self.onFirstContentReady = onFirstContentReady
            self.onVisibleDatesChanged = onVisibleDatesChanged
            self.onOpenPhoto = onOpenPhoto
            self.onToggleSelection = onToggleSelection
            self.onSelectionChanged = onSelectionChanged
            self.dragOutProvider = dragOutProvider
            self.onDragOutFailed = onDragOutFailed
            self.contextMenuActions = contextMenuActions
            self.onContextMenuAction = onContextMenuAction
        }

        /// Remembers the last applied scroll-to-latest signal, so the representable acts only on a real change
        /// (SwiftUI's update-diffing idiom) - never re-scrolling on an unrelated update pass.
        public final class Coordinator {
            var lastScrollToLatestSignal: Int
            var lastScrollToTopSignal: Int
            var lastRestoreScrollSignal: Int
            var lastContentTransitionSignal: Int

            init(
                initialScrollSignal: Int, initialTopSignal: Int, initialRestoreSignal: Int,
                initialContentTransitionSignal: Int
            ) {
                lastScrollToLatestSignal = initialScrollSignal
                lastScrollToTopSignal = initialTopSignal
                lastRestoreScrollSignal = initialRestoreSignal
                lastContentTransitionSignal = initialContentTransitionSignal
            }
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator(
                initialScrollSignal: scrollToLatestSignal,
                initialTopSignal: scrollToTopSignal,
                initialRestoreSignal: restoreScrollSignal,
                initialContentTransitionSignal: contentTransitionSignal
            )
        }

        @MainActor
        public func makeUIView(context: Context) -> UIKitTimelineGridHostView {
            let view = UIKitTimelineGridHostView()
            view.onFirstContentReady = onFirstContentReady
            view.onVisibleDatesChanged = onVisibleDatesChanged
            view.onOpenPhoto = onOpenPhoto
            view.onToggleSelection = onToggleSelection
            view.onSelectionChanged = onSelectionChanged
            view.dragOutProvider = dragOutProvider
            view.onDragOutFailed = onDragOutFailed
            view.contextMenuActions = contextMenuActions
            view.onContextMenuAction = onContextMenuAction
            view.configure(
                items: items, contentRevision: contentRevision,
                thumbnailFeed: thumbnailFeed, metadataProvider: metadataProvider,
                level: level, gridProfile: gridProfile,
                fillOrder: fillOrder,
                initialViewportPlacement: initialViewportPlacement, displayMode: displayMode,
                selectionMode: selectionMode, selectedUIDs: selectedUIDs,
                uploadBadges: uploadBadges)
            view.setActive(isActive)
            wireProxy(proxy, to: view)
            return view
        }

        @MainActor
        public func updateUIView(_ uiView: UIKitTimelineGridHostView, context: Context) {
            uiView.onFirstContentReady = onFirstContentReady
            uiView.onVisibleDatesChanged = onVisibleDatesChanged
            uiView.onOpenPhoto = onOpenPhoto
            uiView.onToggleSelection = onToggleSelection
            uiView.onSelectionChanged = onSelectionChanged
            uiView.dragOutProvider = dragOutProvider
            uiView.onDragOutFailed = onDragOutFailed
            uiView.contextMenuActions = contextMenuActions
            uiView.onContextMenuAction = onContextMenuAction
            let shouldDissolveContent = contentTransitionSignal != context.coordinator.lastContentTransitionSignal
            if shouldDissolveContent {
                context.coordinator.lastContentTransitionSignal = contentTransitionSignal
                uiView.prepareContentReplacementTransition(prefersReducedMotion: prefersReducedMotion)
            }
            uiView.configure(
                items: items, contentRevision: contentRevision,
                thumbnailFeed: thumbnailFeed, metadataProvider: metadataProvider,
                level: level, gridProfile: gridProfile,
                fillOrder: fillOrder,
                initialViewportPlacement: initialViewportPlacement, displayMode: displayMode,
                selectionMode: selectionMode, selectedUIDs: selectedUIDs,
                uploadBadges: uploadBadges)
            if shouldDissolveContent {
                uiView.completeContentReplacementTransition(prefersReducedMotion: prefersReducedMotion)
            }
            uiView.setActive(isActive)
            wireProxy(proxy, to: uiView)
            // A retap of the active Fotos tab bumps the signal and scrolls to the newest photos. Compare it with the
            // coordinator's last value so this fires once per retap, never on an unrelated update pass.
            if scrollToLatestSignal != context.coordinator.lastScrollToLatestSignal {
                context.coordinator.lastScrollToLatestSignal = scrollToLatestSignal
                uiView.scrollToLatest()
            }
            if scrollToTopSignal != context.coordinator.lastScrollToTopSignal {
                context.coordinator.lastScrollToTopSignal = scrollToTopSignal
                uiView.scrollToTop()
            }
            if restoreScrollSignal != context.coordinator.lastRestoreScrollSignal {
                context.coordinator.lastRestoreScrollSignal = restoreScrollSignal
                if let restoreScrollAnchor {
                    uiView.restoreScrollAnchor(restoreScrollAnchor)
                }
            }
        }

        @MainActor
        private func wireProxy(_ proxy: GridProxy<PhotoUID>?, to view: UIKitTimelineGridHostView) {
            proxy?.currentScrollAnchor = { [weak view] in view?.currentScrollAnchor() }
            proxy?.scrollToLatest = { [weak view] in view?.scrollToLatest() }
            proxy?.zoomIn = { [weak view] in view?.zoomInOneStep() }
            proxy?.zoomOut = { [weak view] in view?.zoomOutOneStep() }
            proxy?.zoomAvailability = { [weak view] in
                view?.zoomAvailability() ?? (canZoomIn: false, canZoomOut: false)
            }
            proxy?.toggleContentMode = { [weak view] in view?.togglePreferredContentMode() }
            proxy?.setContentMode = { [weak view] mode in view?.setPreferredContentMode(mode) }
            proxy?.contentModeState = { [weak view] in
                view?.preferredContentModeState() ?? (mode: .squareFillCrop, toggleAvailable: false)
            }
        }
    }

    @MainActor
    public final class UIKitTimelineGridHostView: UIView {
        private static let gridClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let metalView = UIKitTimelineMetalHostView()
        let scrollView = UIScrollView()
        let contentView = UIView()
        private let profileAdapter = UIKitTimelineGridProfileAdapter()
        private let displayLink: UIKitTimelineDisplayLinkDriver
        private let renderFrameOverride: (() -> GridRenderOutcome)?
        private weak var contentReplacementSnapshot: UIView?
        private var contentReplacementUsesSurfaceFade = false

        private var device: MTLDevice?
        var renderer: MetalGridRenderer?
        var textureCache: MetalGridTextureCache<PhotoUID>?
        /// Local photos edited in Apple Photos; their resident textures upload again.
        private var pendingContentEpochs = PendingContentEpochTracker()
        private var pendingHandovers = PendingHandoverTracker()
        private let uploadBadgeAnimator = GridUploadBadgeAnimator<PhotoUID>()
        var texturePolicy: UIKitMetalGridTexturePolicy?
        private var texturePressureRegistration: MemoryPressureRegistration?
        var thumbnailFeed: UIKitThumbnailFeed?
        private var items: [PhotoItem] = []
        private var configuredContentRevision: UInt64?
        private var deferredOrderUpdate: (items: [PhotoItem], revision: UInt64?)?
        private var hasConfiguredContent = false
        /// Flat UID order for the current items, cached so the per-frame composer input never re-maps the library.
        var itemUIDs: [PhotoUID] = []
        var itemIndexByUID: [PhotoUID: Int] = [:]
        private var levelOverride: Int?
        private var requestedProfile: GridLevelProfile?
        /// The user-driven density level set by pinch. Takes precedence over the profile default so pinch survives
        /// item refreshes; cleared when an explicit external `level` arrives. Nil uses the data-driven profile default.
        var interactiveLevel: Int?
        /// The level captured at pinch-gesture start (the cumulative-scale reference).
        var pinchStartLevel: Int?
        /// Engine-owned live pinch transaction. This mirrors the macOS grid path at the Core boundary: the item under
        /// the fingers is captured once, then every live frame is resolved by `GridZoomTransaction` instead of discrete
        /// per-change reflow.
        var zoomTransaction: GridZoomTransaction?
        var zoomTransactionLevel: CGFloat = 0
        var pinchLockedOffsetY: CGFloat?
        /// Optional cursor-aligned column phase committed after a live pinch. Settled iOS layout must use it everywhere
        /// the macOS layout does (rendering, hit-testing, content size), or the release seam can jump horizontally.
        var committedPhase: Int?
        var commitBridgeTransaction: GridZoomTransaction?
        var commitBridgeLevel = 0
        var commitBridgeScrollY: CGFloat = 0
        var commitBridgePhase: Int?
        var commitBridgeStart: CFTimeInterval = 0
        /// Same shared presentation lattice macOS uses for focus-row levels. iOS owns only gesture/lifecycle
        /// plumbing; GridCore owns the reversible alpha/geometry plan so photos crossfade instead of popping.
        var gridTransition = GridTransitionController()
        var pinchDriver = PinchLiveZoomDriver()
        enum PinchMode { case undecided, lattice, reflow, overviewDissolve }
        var pinchMode: PinchMode = .undecided
        var pinchSettling = false
        var pinchBuiltSegment: (Int, Int)?
        var pinchChainBand: (lo: Int, hi: Int) = (0, 0)
        var pinchPrevSampleTime: CFTimeInterval = 0
        var pinchAdvancePrevTime: CFTimeInterval = 0
        var pinchOverviewSource = 0
        var pinchOverviewTarget = 0
        var pinchOverviewQ: Double = 0
        var pinchOverviewSettleFrom: Double = 0
        var pinchOverviewSettleTo: Double = 0
        var pinchOverviewSettleStart: CFTimeInterval = 0
        let pinchOverviewSettleDuration: CFTimeInterval = 0.16
        var overviewDissolve: OverviewLayerDissolvePlan?
        var displayMode: TileContentDisplayMode = .squareFillCrop
        private var fillOrder: GridFillOrder = .newestBottomTrailing
        /// Selection state, mirrored from SwiftUI each `configure`. In selection mode a tap toggles a cell instead of
        /// opening it, and the grid draws the shared selection decorations (blue outline + checkmark badge).
        var selectionMode = false
        var selectedUIDs: Set<PhotoUID> = []
        private(set) var uploadBadges = PendingUploadBadges.empty
        /// Shared static + on-demand duration/RAW descriptors. The resolver fetches encrypted video duration only
        /// after a resident viewport settles, so metadata cannot outrun thumbnail work while scrolling.
        private lazy var thumbnailOverlayResolver: TimelineThumbnailOverlayResolver = {
            let resolver = TimelineThumbnailOverlayResolver(items: [])
            resolver.onChange = { [weak self] in self?.requestRender() }
            return resolver
        }()
        private var metadataProvider: (any PhotoMetadataProvider)?

        /// Gesture-only workload signal for shared background scheduling. These flags change only at
        /// UIKit interaction boundaries; a mounted or repeatedly warming grid remains idle.
        var scrollInputActive = false
        var pinchInputActive = false
        private var reportedFeedInteractionActive = false
        /// This host's identity in the shared feed's interaction aggregate: several windows scroll the same feed,
        /// and each grid must add or remove only its own gesture.
        let interactionOwner = ThumbnailInteractionOwner()
        var warmTask: Task<Void, Never>?
        var lastWarmIDs: [PhotoUID] = []
        /// Scroll-direction-biased prefetch (shared `GridScrollAheadPolicy`): the user's last vertical travel
        /// direction, learned from finger scrolls only (`nil` until the first real scroll - no direction, no
        /// ahead-warm). Reset when the content set changes.
        var scrollDirectionDown: Bool?
        private var lastScrollY: CGFloat = 0
        /// One ahead-warm at a time, keyed by (range, direction, level) so a settled static viewport never
        /// re-issues the same prefetch. RAM-neutral: it decodes into the existing budgets at
        /// `.nearViewportScrollAhead` priority and never runs while visible warm work is pending.
        var aheadWarmTask: Task<Void, Never>?
        var aheadWarmInFlight = false
        var lastAheadKey = ""
        /// True while a `warmDecoded` pass is running, so passes never stack. The warm gate reissues a pass when the
        /// still-missing visible set changes or `warmNeedsRepass` is raised by an arrival or demand move, so a tile
        /// that lands on disk under a static viewport is decoded from disk to RAM on the next warm pass.
        var warmInFlight = false
        /// Monotonic id for the in-flight warm pass. A pass's completion only mutates `warmInFlight` when its id is
        /// still current, so a stale pass cancelled by a detach can never clear the flag out from under a newer pass
        /// (which would briefly permit two overlapping warms right after a tab re-attach).
        var warmGeneration = 0
        /// Raised by the feed's arrival wake (a download landed on disk) or when demand moved mid-pass: the next warm
        /// must re-issue even if the visible set is unchanged, so the just-arrived bytes get decoded to RAM.
        var warmNeedsRepass = false
        /// The feed the arrival wake is currently wired to (reference identity), so `configure` re-subscribes only
        /// when a new feed instance arrives (a new session/route), never on every SwiftUI update pass.
        private weak var wiredFeed: UIKitThumbnailFeed?
        private var imagesAvailableWakeRegistration: ThumbnailFeedWakeRegistration?
        private lazy var accessibilityProvider = UIKitTimelineGridAccessibilityProvider(container: self)
        /// Cached grid profile + engine so a plain finger-scroll frame reuses them instead of reconstructing a
        /// `SquareTileGridEngine` (+ its section arrays) and re-resolving the profile every vsync. The profile is a
        /// pure function of the layout size; the engine of (item count, profile) - both change only on
        /// configure / resize, never mid-scroll - so this removes the per-frame allocation churn.
        private var cachedProfile: GridLevelProfile?
        private var cachedProfileLayoutSize: CGSize = .zero
        private var cachedEngine: SquareTileGridEngine?
        private var cachedEngineItemCount = -1
        private var cachedEngineProfileID: String?
        private var cachedEngineFillOrder: GridFillOrder = .newestBottomTrailing
        /// Geometry of the last completed UIKit layout. Rotation changes `bounds` before `layoutSubviews`, while the
        /// scroll view still carries the old content geometry and offset. Keep the old viewport explicitly so the
        /// visible photo can be captured against the layout that actually produced that offset, then re-resolved at
        /// the new width. A raw offset is not layout-invariant when rotation changes the column count.
        private var lastLaidOutViewportSize: CGSize = .zero
        /// The photo that anchored the previous live resize. While its top stays below the top bar, later resizes keep
        /// anchoring it instead of choosing again in each intermediate layout. A real user scroll, an explicit
        /// placement, or a new item set forgets it.
        private var resizeAnchorItemID: PhotoUID?
        private var lastLaidOutSafeAreaInsets: UIEdgeInsets = .zero
        private var initialViewportPlacement: TimelineInitialViewportPlacement = .automatic
        private var needsInitialViewportPlacement = true
        var userHasScrolledTimeline = false
        var isApplyingProgrammaticScroll = false
        /// One-shot per content set: fires once the first settled frame with a resident visible thumbnail is drawn,
        /// mirroring the macOS coordinator. Reset when a new non-empty UID set lands.
        private var firstContentReported = false
        /// Guards the deferred main-queue readiness callback. A cached frame may finish on the same runloop turn
        /// that authoritative UIDs replace it; only the generation that actually rendered may acknowledge itself.
        private var contentGeneration: UInt64 = 0

        /// Coalesces every invalidation (scroll deltas, new items, layout, arrived thumbnails) into at most one
        /// render per display-link tick. Rendering directly from scroll events acquires a drawable per touch delta -
        /// the 3-deep CAMetalLayer pool exhausts within a frame and `nextDrawable()` then blocks the main thread,
        /// which is exactly the scroll stutter this replaces. The pump also retries after a failed present, so a
        /// transiently unavailable drawable (fresh mount, tab re-attach) can never strand a black grid until the
        /// next scroll event.
        var framePump = GridFramePump()
        private var perf = RenderPerfWindow()
        /// Display-link ticks this host has run (diagnostics and hosted tests: a suspended grid must not tick).
        private(set) var renderTickCount: UInt64 = 0
        private let presentationTiming = PresentationTimingAccumulator()
        private var activeDisplayFrame: UIKitTimelineDisplayFrame?
        /// True while the window scene that hosts this grid is in the background (or the whole app is). Set per
        /// scene, not per application: on iPad one window can be hidden while another window of the same account
        /// stays on screen, and only the hidden grid must stop rendering, decoding and warming.
        private var sceneIsBackgrounded = false

        public private(set) var isMetal3Capable = false

        /// Called on the main actor the first time a visible thumbnail is drawn for the current content - the shell's
        /// signal that the launch/loading UI can lift onto a real grid. The remaining thumbnails may still load.
        /// One-shot per content set.
        public var onFirstContentReady: (() -> Void)?

        /// Called on the main actor with the localized date range of the photos on screen, for example
        /// "Oct 24 – 25, 2026", whenever it changes after a drawn frame; nil when no photo is visible.
        public var onVisibleDatesChanged: ((String?) -> Void)?
        private let visibleDatesFormatter = TimelineVisibleDateRangeFormatter()
        private var visibleDateRange: TimelineVisibleDateRange?
        private var visibleDatesText: String?

        /// Called on the main actor when the user taps a photo cell, with the tapped item. The shell presents the viewer.
        public var onOpenPhoto: ((PhotoItem) -> Void)?

        /// Called on the main actor when the user taps a cell while in selection mode, with the tapped item. The shell
        /// toggles that item's membership in the selection set.
        public var onToggleSelection: ((PhotoItem) -> Void)?

        /// Called on the main actor with the complete selection whenever a swipe selection changes it. Setting nil
        /// disables swipe selection; tap and accessibility toggles still use `onToggleSelection`.
        public var onSelectionChanged: ((Set<PhotoUID>) -> Void)? {
            didSet { swipeSelection.updateEnabled() }
        }

        /// The original-file backend that powers native drag-out. Setting it installs the drag interaction;
        /// setting nil removes drag-out support without affecting tap or zoom.
        public var dragOutProvider: (any OriginalFileProvider)? {
            didSet {
                installDragOutInteractionIfNeeded()
            }
        }

        /// Called on the main actor with (lifted item count, staged fraction in 0...1) while originals are being
        /// staged for an active drag-out session. The shell may use it for progress surfacing.
        public var dragOutProgressReporter: ((Int, Double) -> Void)?

        /// Called on the main actor when a drag-out cannot be delivered, with the coarse failure cause.
        public var onDragOutFailed: ((DragOutFailureKind) -> Void)?
        var contextMenuActions: (([PhotoItem]) -> [PhotoContextMenuAction])?
        var onContextMenuAction: ((PhotoContextMenuAction, [PhotoItem]) -> Void)?

        /// Retained drag-out machinery; owned by the host but implemented entirely in
        /// UIKitTimelineGridHostDrag.swift to keep this file focused on hosting duties.
        var dragOutController: UIKitTimelineGridDragOutController?

        /// Photos-style swipe and press-and-hold range selection; implemented in
        /// UIKitTimelineGridHostSwipeSelection.swift.
        private(set) lazy var swipeSelection = UIKitTimelineGridSwipeSelectionController(host: self)

        public override init(frame: CGRect = .zero) {
            displayLink = UIKitTimelineDisplayLinkDriver()
            renderFrameOverride = nil
            super.init(frame: frame)
            configureSubviews()
            configureMetal()
        }

        init(
            frame: CGRect = .zero,
            displayLink: UIKitTimelineDisplayLinkDriver,
            renderFrame: @escaping () -> GridRenderOutcome
        ) {
            self.displayLink = displayLink
            renderFrameOverride = renderFrame
            super.init(frame: frame)
            configureSubviews()
            configureMetal()
            isMetal3Capable = true
        }

        public required init?(coder: NSCoder) {
            displayLink = UIKitTimelineDisplayLinkDriver()
            renderFrameOverride = nil
            super.init(coder: coder)
            configureSubviews()
            configureMetal()
        }

        deinit {
            // A host released mid-gesture must not leave its owner registered in the shared feed.
            if reportedFeedInteractionActive {
                wiredFeed?.setUserInteractionActive(false, owner: interactionOwner)
            }
            let finalDisplayLink = displayLink
            let finalImagesAvailableWakeRegistration = imagesAvailableWakeRegistration
            let finalTexturePressureRegistration = texturePressureRegistration
            let finalWarmTask = warmTask
            NotificationCenter.default.removeObserver(self)
            finalImagesAvailableWakeRegistration?.end()
            Task { @MainActor in
                finalDisplayLink.stop()
                finalTexturePressureRegistration?.end()
            }
            finalWarmTask?.cancel()
        }

        public func configure(
            items: [PhotoItem],
            contentRevision: UInt64? = nil,
            thumbnailFeed: UIKitThumbnailFeed,
            metadataProvider: (any PhotoMetadataProvider)? = nil,
            level: Int? = nil,
            gridProfile: GridLevelProfile? = nil,
            fillOrder: GridFillOrder = .newestBottomTrailing,
            initialViewportPlacement: TimelineInitialViewportPlacement = .automatic,
            displayMode: TileContentDisplayMode = .squareFillCrop,
            selectionMode: Bool = false,
            selectedUIDs: Set<PhotoUID> = [],
            uploadBadges: PendingUploadBadges = .empty
        ) {
            self.selectionMode = selectionMode
            self.selectedUIDs = selectedUIDs
            // Upload badges change with progress; they never rebuild the item overlays.
            self.uploadBadges = uploadBadges
            thumbnailOverlayResolver.updateUploadBadges(uploadBadges)
            for handover in pendingHandovers.newHandovers(in: uploadBadges.handovers) {
                textureCache?.adoptTexture(from: handover.local, to: handover.remote)
                uploadBadgeAnimator.adopt(from: handover.local, to: handover.remote)
            }
            let revisedContent = pendingContentEpochs.changes(in: uploadBadges.contentEpochs)
            if !revisedContent.isEmpty {
                textureCache?.markStale(revisedContent)
                requestRender()
            }
            swipeSelection.updateEnabled()
            let feedChanged = wiredFeed !== thumbnailFeed
            var contentChanged: Bool
            if let contentRevision {
                contentChanged =
                    feedChanged
                    || !hasConfiguredContent
                    || configuredContentRevision != contentRevision
            } else {
                // Collection and map grids can omit a revision. Array equality retains Swift's shared-storage fast
                // path and preserves their existing behavior until their owners expose a monotonic identity.
                contentChanged = feedChanged || !hasConfiguredContent || items != self.items
            }
            var isOrderCorrection = false
            var orderAnchor: GridScrollAnchor<PhotoUID>?
            if contentChanged, !feedChanged, hasConfiguredContent,
                fillOrder == self.fillOrder, gridProfile == requestedProfile,
                initialViewportPlacement == self.initialViewportPlacement
            {
                if let contentRevision, deferredOrderUpdate?.revision == contentRevision {
                    contentChanged = false
                } else {
                    let visible = Set(accessibilityFramePlan()?.visibleSlots.map(\.index) ?? [])
                    let decision = TimelineOrderRefinementPolicy.decision(
                        incoming: items, previousCount: self.items.count, visibleIndices: visible,
                        previous: { uid in self.itemIndexByUID[uid].map { ($0, self.items[$0]) } })
                    isOrderCorrection = decision != .ordinaryUpdate
                    if decision == .deferVisibleCorrection || (isOrderCorrection && !canRefineOrder) {
                        deferredOrderUpdate = (items, contentRevision)
                        contentChanged = false
                    } else {
                        deferredOrderUpdate = nil
                        if isOrderCorrection { orderAnchor = currentScrollAnchor() }
                    }
                }
            } else if contentChanged {
                deferredOrderUpdate = nil
            }
            let newUIDs = contentChanged ? items.map(\.uid) : itemUIDs
            let uidsChanged = contentChanged && itemUIDs != newUIDs
            if contentChanged {
                self.items = items
                configuredContentRevision = contentRevision
                hasConfiguredContent = true
                if uidsChanged { itemUIDs = newUIDs }
                thumbnailOverlayResolver.update(items: items)
            } else if contentRevision == nil {
                // Do not let a later revision-bearing caller match an identity from an earlier surface by accident.
                configuredContentRevision = nil
            }
            let shouldPlaceInitialViewport =
                uidsChanged && !isOrderCorrection && !itemUIDs.isEmpty && !userHasScrolledTimeline
            self.thumbnailFeed = thumbnailFeed
            self.metadataProvider = metadataProvider
            if requestedProfile != gridProfile {
                requestedProfile = gridProfile
                cachedProfile = nil
                cachedEngine = nil
                committedPhase = nil
                interactiveLevel = nil
            }
            if fillOrder != self.fillOrder {
                self.fillOrder = fillOrder
                committedPhase = nil
                cachedEngine = nil
                needsInitialViewportPlacement = true
                userHasScrolledTimeline = false
            }
            if initialViewportPlacement != self.initialViewportPlacement {
                self.initialViewportPlacement = initialViewportPlacement
                needsInitialViewportPlacement = true
                userHasScrolledTimeline = false
            }
            // Subscribe to the shared feed-core arrival wake once per feed instance (a new session/route builds a new
            // feed): a background download landing on disk then re-warms + redraws this host, so a visible tile fills
            // without the user having to scroll a nudge further.
            if wiredFeed !== thumbnailFeed {
                wiredFeed?.setUserInteractionActive(false, owner: interactionOwner)
                imagesAvailableWakeRegistration?.end()
                wiredFeed = thumbnailFeed
                reportedFeedInteractionActive = false
                updateFeedInteractionState()
                imagesAvailableWakeRegistration = thumbnailFeed.feedCore.setOnImagesAvailableWake { [weak self] in
                    Task { @MainActor [weak self] in self?.handleImagesAvailable() }
                }
            }
            // An explicit external level is authoritative: it clears any pinch-driven level so the host follows the
            // caller again (a nil level leaves the user's pinch level in place).
            if let level, level != levelOverride {
                interactiveLevel = nil
                committedPhase = nil
                cancelLiveZoomState()
            }
            self.levelOverride = level
            self.displayMode = displayMode
            if uidsChanged {
                // A range anchored in the previous item order cannot continue in the new one.
                swipeSelection.cancel()
                resizeAnchorItemID = nil
                contentGeneration &+= 1
                if !isOrderCorrection { committedPhase = nil }
                cancelLiveZoomState()
                itemIndexByUID = Dictionary(
                    itemUIDs.enumerated().map { ($0.element, $0.offset) },
                    uniquingKeysWith: { _, latest in latest }
                )
                lastWarmIDs = []
                scrollDirectionDown = nil
                lastAheadKey = ""
                if !itemUIDs.isEmpty {
                    // A new content set must report its own first drawn frame.
                    firstContentReported = false
                }
                if shouldPlaceInitialViewport {
                    needsInitialViewportPlacement = true
                } else if itemUIDs.isEmpty {
                    needsInitialViewportPlacement = true
                    userHasScrolledTimeline = false
                }
            }
            refreshContentSize()
            if let orderAnchor { restoreScrollAnchor(orderAnchor, marksTimelineAsScrolled: false) }
            requestRender()
            invalidateAccessibilityElements()
        }

        private var canRefineOrder: Bool {
            !pinchInputActive && !pinchSettling && zoomTransaction == nil && commitBridgeTransaction == nil
                && !gridTransition.isActive && overviewDissolve == nil
        }

        /// A scroll inspects only visible slots. The pending array shares its storage with the publication.
        func applyDeferredOrderIfOffscreen() {
            guard let pending = deferredOrderUpdate, canRefineOrder, let thumbnailFeed else { return }
            let visible = Set(accessibilityFramePlan()?.visibleSlots.map(\.index) ?? [])
            guard
                !TimelineOrderRefinementPolicy.movesVisiblePhoto(
                    incoming: pending.items, visibleIndices: visible, previousUID: { self.itemUIDs[$0] })
            else { return }
            deferredOrderUpdate = nil
            configure(
                items: pending.items, contentRevision: pending.revision,
                thumbnailFeed: thumbnailFeed, metadataProvider: metadataProvider,
                level: levelOverride, gridProfile: requestedProfile, fillOrder: fillOrder,
                initialViewportPlacement: initialViewportPlacement, displayMode: displayMode,
                selectionMode: selectionMode, selectedUIDs: selectedUIDs, uploadBadges: uploadBadges)
        }

        /// Captures the currently presented Metal surface before a projection replacement.
        /// The snapshot stays above the next frame for one short dissolve, matching Photos filter changes.
        public func prepareContentReplacementTransition(prefersReducedMotion: Bool) {
            contentReplacementSnapshot?.removeFromSuperview()
            contentReplacementUsesSurfaceFade = false
            guard !prefersReducedMotion, window != nil, !bounds.isEmpty else { return }
            guard let snapshot = metalView.snapshotView(afterScreenUpdates: false) else {
                // Some GPU families do not expose a CAMetalLayer snapshot. A bounded surface fade still prevents
                // the replacement topology from popping and never changes cell geometry.
                contentReplacementUsesSurfaceFade = true
                metalView.alpha = 0.58
                return
            }
            snapshot.frame = metalView.frame
            snapshot.isUserInteractionEnabled = false
            insertSubview(snapshot, aboveSubview: scrollView)
            contentReplacementSnapshot = snapshot
        }

        public func completeContentReplacementTransition(prefersReducedMotion: Bool) {
            requestRender()
            if contentReplacementUsesSurfaceFade {
                contentReplacementUsesSurfaceFade = false
                guard !prefersReducedMotion else {
                    metalView.alpha = 1
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    UIView.animate(
                        withDuration: 0.16,
                        delay: 0,
                        options: [.curveEaseInOut, .allowAnimatedContent, .beginFromCurrentState]
                    ) {
                        self.metalView.alpha = 1
                    }
                }
                return
            }
            guard let snapshot = contentReplacementSnapshot else { return }
            guard !prefersReducedMotion else {
                snapshot.removeFromSuperview()
                return
            }
            // Let Metal commit the replacement frame before revealing it below the old visual snapshot.
            DispatchQueue.main.async { [weak self, weak snapshot] in
                guard let self, let snapshot, snapshot.superview === self else { return }
                UIView.animate(
                    withDuration: 0.16,
                    delay: 0,
                    options: [.curveEaseInOut, .allowAnimatedContent, .beginFromCurrentState]
                ) {
                    snapshot.alpha = 0
                } completion: { _ in
                    snapshot.removeFromSuperview()
                }
            }
        }

        public override func layoutSubviews() {
            let resizePosition = captureViewportResizePositionIfNeeded()
            super.layoutSubviews()
            metalView.frame = bounds
            scrollView.frame = bounds
            applyContentInsets()
            metalView.updateDrawableSize()
            refreshTextureCacheIfNeeded()
            refreshContentSize()
            restoreViewportResizePosition(resizePosition)
            lastLaidOutViewportSize = bounds.size
            lastLaidOutSafeAreaInsets = safeAreaInsets
            requestRender()
            invalidateAccessibilityElements()
        }

        public override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            setNeedsLayout()
        }

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                suspendRenderLoop()
            } else {
                sceneIsBackgrounded = Self.isBackgrounded(window)
                // Re-attached while the tab is active, resume. If the tab is inactive, stay
                // suspended; `setActive(true)` resumes later (window is present by then).
                if framePump.isActive, !sceneIsBackgrounded { resumeRenderLoop() }
            }
            invalidateAccessibilityElements()
        }

        /// Tab/surface activation from the SwiftUI host. An inactive grid must not keep the display link alive
        /// doing render + warm work that competes with the menus/transitions on screen. This is the platform
        /// plumbing for the shared `GridFramePump` active gate - Core decides "should the loop run", UIKit
        /// supplies the lifecycle event. Only acts on a real transition (the pump reports it), so a steady
        /// stream of identical `updateUIView` calls is free.
        public func setActive(_ active: Bool) {
            guard framePump.setActive(active) else { return }
            if active {
                // Resume only makes sense once we are in a window; otherwise `didMoveToWindow` will resume on
                // attach (the pump is now active), so this is safe either way.
                if window != nil { resumeRenderLoop() }
            } else {
                suspendRenderLoop()
            }
            UIHitchLog.gridActivity(
                active: active, hasWindow: window != nil, displayLinkRunning: displayLink.isRunning,
                warmInFlight: warmInFlight, aheadWarmInFlight: aheadWarmInFlight, items: items.count)
            invalidateAccessibilityElements()
        }

        /// Stop the render loop and drop all in-flight warm work - used both when the view leaves its window and
        /// when the tab deactivates. Visible cache/textures stay resident, so returning redraws immediately.
        private func suspendRenderLoop() {
            displayLink.pause()
            perf.noteLoopPaused(reason: "suspended")
            presentationTiming.resetCadence()
            warmTask?.cancel()
            aheadWarmTask?.cancel()
            aheadWarmInFlight = false
            // Local pending photos download from iCloud outside the warm task; stop the former viewport's loads.
            if let feedCore = thumbnailFeed?.feedCore {
                Task { await feedCore.endLocalVisibleDemand() }
            }
            cancelLiveZoomState()
            swipeSelection.cancel()
            scrollInputActive = false
            pinchInputActive = false
            updateFeedInteractionState()
            warmGeneration &+= 1  // retire the cancelled pass so its late completion can't touch a newer one
            warmInFlight = false  // never leave the warm gate latched shut after a suspend cancels the pass
        }

        /// Re-arm exactly one render on return to the active window, decoding any visible tiles whose bytes
        /// landed while we were suspended (no scroll nudge needed).
        private func resumeRenderLoop() {
            metalView.updateDrawableSize()
            warmNeedsRepass = true
            requestRender()
        }

        private func configureSubviews() {
            backgroundColor = .black
            isAccessibilityElement = false
            shouldGroupAccessibilityChildren = true
            // Scene lifecycle, filtered to this grid's own window scene. The application-level notifications
            // would only fire when every window is hidden.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(sceneDidEnterBackground(_:)),
                name: UIScene.didEnterBackgroundNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(sceneWillEnterForeground(_:)),
                name: UIScene.willEnterForegroundNotification,
                object: nil
            )

            metalView.translatesAutoresizingMaskIntoConstraints = true
            metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(metalView)

            scrollView.translatesAutoresizingMaskIntoConstraints = true
            scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            scrollView.backgroundColor = .clear
            scrollView.isOpaque = false
            scrollView.delegate = self
            scrollView.alwaysBounceVertical = true
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.contentInsetAdjustmentBehavior = .never
            // The native soft edge keeps navigation controls floating over the photo grid on iOS 27.
            // SwiftUI's scrollEdgeEffectStyle does not reach this embedded UIKit scroll surface.
            scrollView.topEdgeEffect.style = .soft
            contentView.backgroundColor = .clear
            scrollView.addSubview(contentView)
            addSubview(scrollView)

            // Tap-to-open and pinch-to-change-density ride on the scroll surface so they coexist with the pan/scroll
            // gesture. The tap requires no movement (never fights a scroll); the pinch drives an engine-owned
            // `GridZoomTransaction` through shared GridCore geometry - no bespoke iOS layout math.
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.delegate = self
            scrollView.addGestureRecognizer(tap)

            // Selection mode only: a horizontal swipe or a press-and-hold selects a range. Releasing a hold must not
            // also toggle its anchor as a tap.
            swipeSelection.install(on: scrollView)
            tap.require(toFail: swipeSelection.hold)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            scrollView.addGestureRecognizer(pinch)
        }

        @objc private func sceneDidEnterBackground(_ notification: Notification) {
            guard hosts(notification.object as? UIScene) else { return }
            hostSceneDidEnterBackground()
        }

        @objc private func sceneWillEnterForeground(_ notification: Notification) {
            guard hosts(notification.object as? UIScene) else { return }
            hostSceneWillEnterForeground()
        }

        /// The hosting window scene left the screen: stop the display link and drop in-flight warm work.
        func hostSceneDidEnterBackground() {
            sceneIsBackgrounded = true
            suspendRenderLoop()
        }

        /// The hosting window scene returns: one render re-arms and decodes tiles that arrived meanwhile.
        func hostSceneWillEnterForeground() {
            sceneIsBackgrounded = false
            guard window != nil, framePump.isActive else { return }
            resumeRenderLoop()
        }

        private func hosts(_ scene: UIScene?) -> Bool {
            guard let scene, let windowScene = window?.windowScene else { return false }
            return scene === windowScene
        }

        private static func isBackgrounded(_ window: UIWindow?) -> Bool {
            guard let scene = window?.windowScene else {
                return UIApplication.shared.applicationState == .background
            }
            return scene.activationState == .background
        }

        private func configureMetal() {
            guard let device = MTLCreateSystemDefaultDevice() else {
                isMetal3Capable = false
                return
            }
            isMetal3Capable = UIKitTimelineMetalCapability.supportsTimelineGrid(device: device)
            guard isMetal3Capable else { return }
            self.device = device
            renderer = MetalGridRenderer(device: device, clearColor: Self.gridClearColor)
            if renderer?.compositePipelineUnavailable == true {
                PhotoDiagnostics.shared.emit("MetalGridRenderer", ["compositePipeline": "unavailable"])
            }
            metalView.configure(device: device)
            refreshTextureCacheIfNeeded()
        }

        private func refreshTextureCacheIfNeeded() {
            guard let device, bounds.width > 0, bounds.height > 0 else { return }
            let policy = UIKitMetalGridTexturePolicies.policy(forViewportSize: bounds.size)
            if texturePolicy == policy, textureCache != nil { return }
            texturePolicy = policy
            let cache: MetalGridTextureCache<PhotoUID>? = UIKitMetalGridTextureCacheFactory.makeCache(
                device: device, policy: policy)
            if let oldCache = textureCache {
                texturePressureRegistration?.end()
                UIKitMemoryPressureCoordinator.shared.detach(oldCache)
                texturePressureRegistration = nil
            }
            textureCache = cache
            // Register the GPU texture cache with the shared memory governor. On pressure the cache sheds offscreen but never
            // the visible pinned set, so what is on screen stays drawable - mirroring the macOS coordinator.
            if let cache {
                texturePressureRegistration = UIKitMemoryPressureCoordinator.shared.attach(cache) { [weak cache] tier in
                    cache?.setResidencyPressureScale(tier.budgetScale)
                }
            }
        }

        /// Keeps the last row of content clear of the bottom bar / home indicator: the scroll surface extends
        /// under the (translucent) bar for the full-bleed look, but the content range ends above it, so fully
        /// scrolled to the newest photo every thumbnail of the final row stays visible and tappable. Safe-area
        /// driven - tab bar, home indicator, orientation and iPad sidebar layouts all flow through the same inset.
        /// Also adds a top inset equal to safeAreaInsets.top so the first row rests below the navigation bar
        /// instead of being covered by it.
        private func applyContentInsets() {
            let top = safeAreaInsets.top
            let bottom = safeAreaInsets.bottom
            if scrollView.contentInset.top != top || scrollView.contentInset.bottom != bottom {
                scrollView.contentInset = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
            }
            scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        }

        /// The largest valid vertical content offset given the current content size and bottom inset.
        var maxContentOffsetY: CGFloat {
            max(0, scrollView.contentSize.height - bounds.height + scrollView.contentInset.bottom)
        }

        func refreshContentSize() {
            let size = resolvedContentSize()
            scrollView.contentSize = size
            contentView.frame = CGRect(origin: .zero, size: size)
            applyInitialViewportPlacementIfNeeded(contentSize: size)
        }

        private func applyInitialViewportPlacementIfNeeded(contentSize: CGSize) {
            guard needsInitialViewportPlacement,
                bounds.width > 0,
                bounds.height > 0,
                !itemUIDs.isEmpty
            else { return }

            // When the content fits within one screen (few photos - e.g. a small map cluster), there is no
            // real scroll room: `resolvedContentSize` floors the height to `bounds.height + 1`, so
            // `maxContentOffsetY` is a ~1pt phantom that would scroll the first row UP under the navigation
            // bar. Rest at `-safeAreaInsets.top` instead so the first row sits just below the bar. Only when
            // the content genuinely overflows do we scroll to the newest (bottom) row.
            let fitsOnScreen = contentSize.height <= bounds.height + 1
            let targetY: CGFloat
            if fitsOnScreen {
                targetY = -safeAreaInsets.top
            } else {
                targetY = initialViewportOpensAtNewest ? maxContentOffsetY : -safeAreaInsets.top
            }
            isApplyingProgrammaticScroll = true
            scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            isApplyingProgrammaticScroll = false
            needsInitialViewportPlacement = false
            resizeAnchorItemID = nil
        }

        private var initialViewportOpensAtNewest: Bool {
            switch initialViewportPlacement {
            case .automatic:
                return fillOrder == .newestBottomTrailing
            case .newest:
                return true
            case .oldest:
                return false
            }
        }

        /// Scrolls the timeline to the newest photos - the bottom-anchored final row - for the "retap the active
        /// Fotos tab" gesture. A pure `contentOffset` move that reuses the same bottom math as the initial newest
        /// viewport: it touches neither the density level, the selection, nor the item set, so it can never reload
        /// or reset the grid. Bracketed by `isApplyingProgrammaticScroll` (matching every other programmatic
        /// scroll here); an animated scroll is additionally exempt from user-scroll learning because it sets none
        /// of isTracking/isDragging/isDecelerating. A no-op when already at the newest row, so retapping at the
        /// bottom never jitters.
        public func scrollToLatest(animated: Bool = true) {
            guard window != nil, bounds.height > 0, !itemUIDs.isEmpty else { return }
            let target = maxContentOffsetY
            guard abs(scrollView.contentOffset.y - target) > 0.5 else { return }
            isApplyingProgrammaticScroll = true
            scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: animated)
            isApplyingProgrammaticScroll = false
            requestRender()
        }

        /// Places a bounded top-leading projection below the native navigation inset. This is an explicit route
        /// placement, not a learned user position, so later projection changes can still apply their own contract.
        public func scrollToTop(animated: Bool = false) {
            guard window != nil, bounds.height > 0, !itemUIDs.isEmpty else { return }
            // An explicit placement chooses a new place, like a scroll; the next resize anchors at the top.
            resizeAnchorItemID = nil
            let target = -safeAreaInsets.top
            guard abs(scrollView.contentOffset.y - target) > 0.5 else { return }
            isApplyingProgrammaticScroll = true
            scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: animated)
            isApplyingProgrammaticScroll = false
            needsInitialViewportPlacement = false
            userHasScrolledTimeline = false
            requestRender()
        }

        func setPreferredContentMode(_ mode: TileContentDisplayMode) {
            guard displayMode != mode else { return }
            displayMode = mode
            requestRender()
        }

        func togglePreferredContentMode() {
            let next: TileContentDisplayMode =
                displayMode == .squareFillCrop
                ? .aspectFitInsideSquare
                : .squareFillCrop
            setPreferredContentMode(next)
        }

        func preferredContentModeState() -> (mode: TileContentDisplayMode, toggleAvailable: Bool) {
            guard let context = currentGridContext() else {
                return (displayMode, false)
            }
            return (displayMode, context.engine.contentModeToggleAvailable(level: context.level))
        }

        /// Captures the first photo below the top bar plus its offset. The shell can restore this after temporarily
        /// replacing the item projection (for example while Smart Search is active) without guessing a raw offset.
        public func currentScrollAnchor() -> GridScrollAnchor<PhotoUID>? {
            guard bounds.width > 0, bounds.height > 0, !itemUIDs.isEmpty else { return nil }
            let profile = currentProfile()
            let level = activeLevel(profile: profile)
            let engine = currentEngine(profile: profile)
            let plan = engine.framePlan(
                level: level,
                viewportSize: bounds.size,
                scrollOffset: scrollView.contentOffset,
                overscan: 0,
                columnPhase: committedPhase
            )
            guard
                let top = GridScrollAnchorPolicy.anchor(
                    among: plan.visibleSlots,
                    visibleTop: scrollView.contentOffset.y + safeAreaInsets.top,
                    visibleBottom: scrollView.contentOffset.y + bounds.height - safeAreaInsets.bottom,
                    frame: \.slotRect),
                itemUIDs.indices.contains(top.index)
            else { return nil }
            return GridScrollAnchor(
                itemID: itemUIDs[top.index],
                topOffset: top.slotRect.minY - scrollView.contentOffset.y
            )
        }

        /// Re-resolves a captured photo through the current width, density and phase, then restores it to the
        /// same viewport position. If the item disappeared, the current position is left untouched.
        public func restoreScrollAnchor(_ anchor: GridScrollAnchor<PhotoUID>) {
            resizeAnchorItemID = nil
            restoreScrollAnchor(anchor, marksTimelineAsScrolled: true)
        }

        private func restoreScrollAnchor(
            _ anchor: GridScrollAnchor<PhotoUID>,
            marksTimelineAsScrolled: Bool
        ) {
            guard bounds.width > 0,
                let index = itemIndexByUID[anchor.itemID]
            else { return }
            let profile = currentProfile()
            let level = activeLevel(profile: profile)
            let engine = currentEngine(profile: profile)
            guard
                let rect = engine.slotRect(
                    flatIndex: index,
                    level: level,
                    width: bounds.width,
                    columnPhase: committedPhase
                )
            else { return }
            let targetY = min(max(rect.minY - anchor.topOffset, -safeAreaInsets.top), maxContentOffsetY)
            isApplyingProgrammaticScroll = true
            scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            isApplyingProgrammaticScroll = false
            needsInitialViewportPlacement = false
            if marksTimelineAsScrolled {
                userHasScrolledTimeline = true
            }
            requestRender()
        }

        private enum ViewportResizePosition {
            case newest
            case anchor(GridScrollAnchor<PhotoUID>)
        }

        /// Capture against the previous layout, not the already-mutated `bounds`: the scroll offset belongs to the
        /// previous column geometry until `refreshContentSize()` resolves the new one. Preserve the newest edge as an
        /// edge; otherwise preserve the first photo below the top bar plus its distance to the bar.
        private func captureViewportResizePositionIfNeeded() -> ViewportResizePosition? {
            guard lastLaidOutViewportSize.width > 0,
                lastLaidOutViewportSize.height > 0,
                !needsInitialViewportPlacement,
                !itemUIDs.isEmpty,
                let profile = cachedProfile,
                viewportGeometryChangedSinceLastLayout
            else { return nil }

            let oldMaximumY = max(
                0,
                scrollView.contentSize.height - lastLaidOutViewportSize.height
                    + lastLaidOutSafeAreaInsets.bottom
            )
            if abs(scrollView.contentOffset.y - oldMaximumY) <= 2 {
                resizeAnchorItemID = nil
                return .newest
            }

            let level = activeLevel(profile: profile)
            let engine = SquareTileGridEngine(
                sectionCounts: [items.count], profile: profile, fillOrder: fillOrder
            )
            let plan = engine.framePlan(
                level: level,
                viewportSize: lastLaidOutViewportSize,
                scrollOffset: scrollView.contentOffset,
                overscan: 0,
                columnPhase: committedPhase
            )
            // The usable area of the previous layout: below the translucent top bar, above the bottom bar. A rotation
            // lays out several intermediate sizes, and repeated Split View or Stage Manager resizes follow each other;
            // keep the photo anchored by the first of them while its top stays in that area, so the place does not
            // creep with each layout or column count.
            let visibleTop = scrollView.contentOffset.y + lastLaidOutSafeAreaInsets.top
            let visibleBottom =
                scrollView.contentOffset.y + lastLaidOutViewportSize.height - lastLaidOutSafeAreaInsets.bottom
            let remembered = resizeAnchorItemID
            guard
                let anchorSlot = GridScrollAnchorPolicy.anchor(
                    among: plan.visibleSlots, visibleTop: visibleTop, visibleBottom: visibleBottom,
                    isKept: { [itemUIDs] in itemUIDs.indices.contains($0.index) && itemUIDs[$0.index] == remembered },
                    frame: \.slotRect),
                itemUIDs.indices.contains(anchorSlot.index)
            else { return nil }
            resizeAnchorItemID = itemUIDs[anchorSlot.index]
            // Keep the photo's distance to the bar, not to the viewport top: rotation changes the bar height.
            return .anchor(
                GridScrollAnchor(
                    itemID: itemUIDs[anchorSlot.index],
                    topOffset: anchorSlot.slotRect.minY - visibleTop + safeAreaInsets.top
                ))
        }

        private var viewportGeometryChangedSinceLastLayout: Bool {
            abs(lastLaidOutViewportSize.width - bounds.width) > 0.5
                || abs(lastLaidOutViewportSize.height - bounds.height) > 0.5
                || lastLaidOutSafeAreaInsets != safeAreaInsets
        }

        private func restoreViewportResizePosition(_ position: ViewportResizePosition?) {
            guard let position else { return }
            switch position {
            case .newest:
                isApplyingProgrammaticScroll = true
                scrollView.setContentOffset(CGPoint(x: 0, y: maxContentOffsetY), animated: false)
                isApplyingProgrammaticScroll = false
            case .anchor(let anchor):
                restoreScrollAnchor(anchor, marksTimelineAsScrolled: false)
            }
        }

        private func resolvedContentSize() -> CGSize {
            guard bounds.width > 0, !items.isEmpty else { return bounds.size }
            let profile = currentProfile()
            let level = activeLevel(profile: profile)
            let engine = currentEngine(profile: profile)
            let content = engine.contentSize(level: level, width: bounds.width, columnPhase: committedPhase)
            return CGSize(width: max(bounds.width, content.width), height: max(bounds.height + 1, content.height))
        }

        private func activeLevel(profile: GridLevelProfile) -> Int {
            profile.clampLevel(interactiveLevel ?? levelOverride ?? profile.defaultLevel)
        }

        /// True while the user is actively scrolling, decelerating, or pinching. The shared soft-to-sharp upgrade path
        /// is gated off during interaction (so it does not churn uploads or drop frames mid-gesture) and back on once
        /// the grid settles. This schedules the shared composer upgrade.
        private var isInteracting: Bool {
            scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating || pinchStartLevel != nil
                || zoomTransaction != nil || commitBridgeTransaction != nil
                || gridTransition.isActive || overviewDissolve != nil || pinchSettling
        }

        /// The grid profile for the current layout size, rebuilt only when that size changes (never mid-scroll).
        /// The profile is a pure function of the usable layout size, so caching on it keeps a plain scroll frame
        /// from re-resolving the density ladder every vsync. It reads the host's own safe area: during a rotation the
        /// Metal subview still reports the insets of the previous layout, which picked the other ladder for one pass
        /// and moved the density and the place.
        func currentProfile() -> GridLevelProfile {
            let layoutSize = UIKitTimelineGridProfileAdapter.layoutSize(
                forBounds: bounds, safeAreaInsets: safeAreaInsets)
            if let cachedProfile, cachedProfileLayoutSize == layoutSize { return cachedProfile }
            let previousProfile = cachedProfile
            let previousLayoutSize = cachedProfileLayoutSize
            if previousProfile != nil {
                committedPhase = nil
                cancelLiveZoomState()
            }
            let profile = requestedProfile ?? profileAdapter.profile(for: self)
            if let previousProfile, previousProfile.id != profile.id,
                previousLayoutSize.width > 0, layoutSize.width > 0
            {
                let sourceLevel = activeLevel(profile: previousProfile)
                let sourceEngine = SquareTileGridEngine(
                    sectionCounts: [items.count], profile: previousProfile, fillOrder: fillOrder
                )
                let targetEngine = SquareTileGridEngine(
                    sectionCounts: [items.count], profile: profile, fillOrder: fillOrder
                )
                interactiveLevel = sourceEngine.closestVisualLevel(
                    sourceLevel: sourceLevel,
                    sourceWidth: previousLayoutSize.width,
                    in: targetEngine,
                    targetWidth: layoutSize.width
                )
            }
            cachedProfile = profile
            cachedProfileLayoutSize = layoutSize
            // A profile change can change the level ladder, so the engine keyed on it must rebuild too.
            cachedEngine = nil
            return profile
        }

        /// The canonical geometry engine for the current item count + profile, rebuilt only when either changes.
        /// A finger-scroll changes neither, so the engine (and its section arrays) is constructed once, not per frame.
        func currentEngine(profile: GridLevelProfile) -> SquareTileGridEngine {
            if let cachedEngine, cachedEngineItemCount == items.count, cachedEngineProfileID == profile.id,
                cachedEngineFillOrder == fillOrder
            {
                return cachedEngine
            }
            let engine = SquareTileGridEngine(sectionCounts: [items.count], profile: profile, fillOrder: fillOrder)
            cachedEngine = engine
            cachedEngineItemCount = items.count
            cachedEngineProfileID = profile.id
            cachedEngineFillOrder = fillOrder
            return engine
        }

        // MARK: - Coalesced render loop

        /// Mark the on-screen state dirty and make sure the display link is ticking. All invalidations funnel
        /// through here; actual drawing happens only in `tick`, at most once per vsync.
        func requestRender() {
            guard isMetal3Capable else { return }
            framePump.invalidate()
            // Start the loop only when the surface can actually draw: in a window AND active (the pump gates
            // `shouldTick` on active). A hidden/inactive grid stays marked dirty, so returning re-arms it, but
            // never spins the display link while menus/other tabs are on screen.
            guard let window, !sceneIsBackgrounded, framePump.shouldTick else { return }
            let maximumFramesPerSecond = window.screen.maximumFramesPerSecond
            if !displayLink.isRunning {
                displayLink.start(maximumFramesPerSecond: maximumFramesPerSecond) { [weak self] frame in
                    self?.tick(frame)
                }
            } else {
                displayLink.configure(maximumFramesPerSecond: maximumFramesPerSecond)
            }
        }

        private func tick(_ frame: UIKitTimelineDisplayFrame) {
            renderTickCount &+= 1
            perf.notePresentation(presentationTiming.drain())
            guard framePump.beginTick() else {
                // An input phase can remain active while a finger is stationary. A clean pump has no
                // work even then; the next scroll/thumbnail invalidation resumes this same installed link.
                perf.noteLoopPaused(reason: "idle")
                presentationTiming.resetCadence()
                displayLink.pause()
                return
            }
            activeDisplayFrame = frame
            advancePinchSettleIfNeeded()
            let outcome = renderNow()
            activeDisplayFrame = nil
            publishVisibleDates()
            let keepTicking = framePump.completeTick(outcome)
            var drawableFailed = false
            if case .noDrawable = outcome { drawableFailed = true }
            var drew = false
            if case .drawn = outcome { drew = true }
            let completedAt = CACurrentMediaTime()
            perf.noteTick(
                frame: frame,
                phase: currentScrollPhase,
                drew: drew,
                drawableFailed: drawableFailed,
                completedAt: completedAt
            )
            if !keepTicking, !renderLoopHasActiveMotion {
                perf.noteLoopPaused(reason: "idle")
                presentationTiming.resetCadence()
                displayLink.pause()
            }
        }

        private var currentScrollPhase: UIKitGridScrollPhase {
            if scrollView.isTracking { return .tracking }
            if scrollView.isDecelerating { return .decelerating }
            if scrollView.isDragging || scrollInputActive {
                return .dragging
            }
            if pinchStartLevel != nil || zoomTransaction != nil || commitBridgeTransaction != nil
                || gridTransition.isActive || overviewDissolve != nil || pinchSettling
            {
                return .animating
            }
            return .idle
        }

        private var renderLoopHasActiveMotion: Bool {
            currentScrollPhase != .idle
        }

        @discardableResult
        private func renderNow() -> GridRenderOutcome {
            if let renderFrameOverride { return renderFrameOverride() }
            guard isMetal3Capable,
                bounds.width > 0,
                bounds.height > 0,
                let renderer,
                let textureCache,
                let texturePolicy
            else { return .skippedNoSurface }
            let viewportSize = bounds.size
            let overscan = texturePolicy.budget.overscanFraction * viewportSize.height
            let profile = currentProfile()
            let level = activeLevel(profile: profile)
            let engine = currentEngine(profile: profile)

            if let dissolve = overviewDissolve {
                return renderOverviewDissolve(
                    renderer: renderer,
                    textureCache: textureCache,
                    plan: dissolve,
                    viewportSize: viewportSize
                )
            }

            if gridTransition.isActive {
                return renderTransitionFrame(
                    renderer: renderer,
                    textureCache: textureCache,
                    viewportSize: viewportSize
                )
            }

            if let tx = commitBridgeTransaction {
                let elapsed = max(0, CACurrentMediaTime() - commitBridgeStart)
                if elapsed < GridZoomCommitBridge.duration {
                    let slots = GridZoomCommitBridge.frame(
                        transaction: tx,
                        engine: engine,
                        targetLevel: commitBridgeLevel,
                        viewportSize: viewportSize,
                        scrollY: commitBridgeScrollY,
                        overscan: overscan,
                        progress: CGFloat(elapsed / GridZoomCommitBridge.duration),
                        columnPhase: commitBridgePhase
                    )
                    let metrics = engine.resolvedMetrics(level: commitBridgeLevel, width: bounds.width)
                    return renderSlotFrame(
                        renderer: renderer,
                        textureCache: textureCache,
                        slots: slots,
                        slotSidePoints: metrics.slotSide,
                        viewportSize: viewportSize,
                        allowUpgrade: false,
                        reportFirstContent: false,
                        forcePendingWork: true
                    )
                }
                commitBridgeTransaction = nil
                commitBridgeStart = 0
            }

            if let tx = zoomTransaction {
                let frame = tx.frame(
                    continuousLevel: zoomTransactionLevel, viewportSize: viewportSize, overscan: overscan)
                return renderSlotFrame(
                    renderer: renderer,
                    textureCache: textureCache,
                    slots: frame.visibleSlots,
                    slotSidePoints: frame.slotSide,
                    viewportSize: viewportSize,
                    allowUpgrade: false,
                    reportFirstContent: false,
                    forcePendingWork: false
                )
            }

            let plan = engine.framePlan(
                level: level,
                viewportSize: viewportSize,
                scrollOffset: scrollView.contentOffset,
                overscan: overscan,
                columnPhase: committedPhase
            )

            let outcome = renderSlotFrame(
                renderer: renderer,
                textureCache: textureCache,
                slots: renderSlots(from: plan.visibleSlots),
                slotSidePoints: plan.slotSide,
                viewportSize: viewportSize,
                allowUpgrade: !isInteracting,
                reportFirstContent: true,
                forcePendingWork: false
            )
            // Settled frames only: pre-decode the next rows in the user's travel direction from disk to RAM so
            // resuming the scroll lands on RAM-ready tiles. Never during interaction, never over visible work.
            if !isInteracting {
                scheduleScrollAheadWarmIfIdle(plan: plan)
            }
            return outcome
        }

        private func renderTransitionFrame(
            renderer: MetalGridRenderer,
            textureCache: MetalGridTextureCache<PhotoUID>,
            viewportSize: CGSize
        ) -> GridRenderOutcome {
            let cpuPreparationStarted = CACurrentMediaTime()
            let now = CACurrentMediaTime()
            let draws = gridTransition.currentDraws()
            guard !draws.isEmpty else { return .drawn(hasPendingWork: false) }
            let slotSide = draws.reduce(CGFloat(64)) { partial, draw in
                max(partial, max(draw.rect.width, draw.rect.height))
            }
            let uids = uniqueUIDs(
                draws.compactMap { draw -> PhotoUID? in
                    draw.index >= 0 && draw.index < itemUIDs.count ? itemUIDs[draw.index] : nil
                })
            streamTransitionTextures(uids: uids, slotSidePoints: slotSide, textureCache: textureCache)
            let groups = MetalGridFrameComposer.buildTransitionGroups(
                draws: draws,
                flatUIDs: itemUIDs,
                cache: textureCache,
                displayMode: displayMode,
                cornerRadius: GridVisualConstants.thumbnailCornerRadius,
                decorations: productionDecorations(),
                now: now
            ).groups
            textureCache.evictToBudget()
            guard let acquisition = acquireDrawableTarget() else { return .noDrawable }
            let cpuPreparationMs = (acquisition.startedAt - cpuPreparationStarted) * 1000
            renderer.render(to: acquisition.target, viewportSize: viewportSize, groups: groups)
            return finishTransitionDraw(
                uids: uids, slotSidePoints: slotSide, textureCache: textureCache, renderer: renderer,
                cpuPreparationMs: cpuPreparationMs, drawableWaitMs: acquisition.waitMs, now: now)
        }

        /// Shared tail of every transition/dissolve frame: warm the still-missing tiles at the transition's
        /// upload size, record the draw, and keep ticking only while settle/warm/upload progress is possible.
        private func finishTransitionDraw(
            uids: [PhotoUID],
            slotSidePoints: CGFloat,
            textureCache: MetalGridTextureCache<PhotoUID>,
            renderer: MetalGridRenderer,
            cpuPreparationMs: Double,
            drawableWaitMs: Double,
            now: Double = CACurrentMediaTime()
        ) -> GridRenderOutcome {
            let (missing, ramReadyMissing) = missingRetryableTiles(in: uids, isResident: textureCache.isResident)
            scheduleWarmIfNeeded(
                missing, pixelSize: transitionUploadPixels(slotSidePoints: slotSidePoints, textureCache: textureCache))
            perf.noteDraw(
                visible: uids.count, missing: missing.count,
                ramHitGpuMiss: ramReadyMissing, saturated: textureCache.residencySaturatedThisFrame,
                cache: textureCache, cpuPreparationMs: cpuPreparationMs,
                drawableWaitMs: drawableWaitMs, frameBoundaryWaitMs: renderer.lastFrameBoundaryWaitMs,
                rendererEncodeMs: renderer.lastEncodeMs, gpuMs: renderer.lastCompletedGpuMs)
            let activeReveal =
                textureCache.hasActiveThumbnailReveal(in: uids, now: now)
                || uploadBadgeAnimator.isAnimating(uids, now: now)
            return .drawn(hasPendingWork: pinchSettling || warmInFlight || ramReadyMissing > 0 || activeReveal)
        }

        private func renderOverviewDissolve(
            renderer: MetalGridRenderer,
            textureCache: MetalGridTextureCache<PhotoUID>,
            plan: OverviewLayerDissolvePlan,
            viewportSize: CGSize
        ) -> GridRenderOutcome {
            let cpuPreparationStarted = CACurrentMediaTime()
            let now = CACurrentMediaTime()
            let sourceSlots = renderSlots(from: plan.source.visibleSlots)
            let targetSlots = renderSlots(from: plan.target.visibleSlots)
            let allSlots = sourceSlots + targetSlots
            let uids = uniqueUIDs(
                allSlots.compactMap { slot -> PhotoUID? in
                    slot.index >= 0 && slot.index < itemUIDs.count ? itemUIDs[slot.index] : nil
                })
            let slotSide = allSlots.reduce(CGFloat(64)) { partial, slot in
                max(partial, max(slot.rect.width, slot.rect.height))
            }
            let sourceResidentBefore = residentSlotCount(sourceSlots, textureCache: textureCache)
            let targetResidentBefore = residentSlotCount(targetSlots, textureCache: textureCache)
            streamTransitionTextures(uids: uids, slotSidePoints: slotSide, textureCache: textureCache)
            let sourceResidentAfter = residentSlotCount(sourceSlots, textureCache: textureCache)
            let targetResidentAfter = residentSlotCount(targetSlots, textureCache: textureCache)
            let activeReveal =
                textureCache.hasActiveThumbnailReveal(in: uids, now: now)
                || uploadBadgeAnimator.isAnimating(uids, now: now)
            textureCache.evictToBudget()
            let sourceGroups = MetalGridFrameComposer.buildGroups(
                slots: MetalGridFrameComposer.viewportDrawSlots(sourceSlots, viewportSize: viewportSize),
                flatUIDs: itemUIDs,
                cache: textureCache,
                displayMode: plan.sourceDisplayMode,
                cornerRadius: GridVisualConstants.thumbnailCornerRadius,
                decorations: productionDecorations(),
                now: now
            ).groups
            let targetGroups = MetalGridFrameComposer.buildGroups(
                slots: MetalGridFrameComposer.viewportDrawSlots(targetSlots, viewportSize: viewportSize),
                flatUIDs: itemUIDs,
                cache: textureCache,
                displayMode: plan.targetDisplayMode,
                cornerRadius: GridVisualConstants.thumbnailCornerRadius,
                decorations: productionDecorations(),
                now: now
            ).groups
            guard let acquisition = acquireDrawableTarget() else { return .noDrawable }
            let cpuPreparationMs = (acquisition.startedAt - cpuPreparationStarted) * 1000
            renderer.renderLayerDissolve(
                to: acquisition.target,
                viewportSize: viewportSize,
                redrawSource: sourceResidentAfter != sourceResidentBefore || activeReveal,
                redrawTarget: targetResidentAfter != targetResidentBefore || activeReveal,
                sourceGroups: { sourceGroups },
                targetGroups: { targetGroups },
                t: Float(plan.targetOpacity)
            )
            return finishTransitionDraw(
                uids: uids, slotSidePoints: slotSide, textureCache: textureCache, renderer: renderer,
                cpuPreparationMs: cpuPreparationMs, drawableWaitMs: acquisition.waitMs, now: now)
        }

        private func streamTransitionTextures(
            uids: [PhotoUID],
            slotSidePoints: CGFloat,
            textureCache: MetalGridTextureCache<PhotoUID>
        ) {
            guard !uids.isEmpty else { return }
            let feed = thumbnailFeed
            let uploadPixels = transitionUploadPixels(slotSidePoints: slotSidePoints, textureCache: textureCache)
            textureCache.setEffectiveMaxTexturePixels(uploadPixels)
            textureCache.beginFrame(pinned: Set(uids))
            textureCache.uploadVisible(wanted: uids) { feed?.memoryCGImage(for: $0) }
        }

        func transitionUploadPixels(
            slotSidePoints: CGFloat,
            textureCache: MetalGridTextureCache<PhotoUID>
        ) -> Int {
            GridTextureUploadSizing.uploadPixels(
                slotSidePoints: slotSidePoints,
                backingScale: metalView.metalLayer.contentsScale,
                headroom: 1.15,
                floor: 64,
                cap: textureCache.maxTexturePixels
            )
        }

        private func renderSlots(from slots: [GridSlot]) -> [GridRenderSlot] {
            slots.map { GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect) }
        }

        private func residentSlotCount(_ slots: [GridRenderSlot], textureCache: MetalGridTextureCache<PhotoUID>) -> Int
        {
            slots.reduce(into: 0) { count, slot in
                guard slot.index >= 0, slot.index < itemUIDs.count else { return }
                if textureCache.isResident(itemUIDs[slot.index]) { count += 1 }
            }
        }

        private lazy var composeSignposts = MetalGridComposeSignposts(
            uploadInterval: { PhotoPerformanceSignposts.grid.interval("streamTextures.upload", $0) },
            upgradeInterval: { PhotoPerformanceSignposts.grid.interval("streamTextures.upgrade", $0) }
        )

        func uniqueUIDs(_ uids: [PhotoUID]) -> [PhotoUID] {
            var seen = Set<PhotoUID>()
            return uids.filter { seen.insert($0).inserted }
        }

        private func renderSlotFrame(
            renderer: MetalGridRenderer,
            textureCache: MetalGridTextureCache<PhotoUID>,
            slots: [GridRenderSlot],
            slotSidePoints: CGFloat,
            viewportSize: CGSize,
            allowUpgrade: Bool,
            reportFirstContent: Bool,
            forcePendingWork: Bool
        ) -> GridRenderOutcome {
            let cpuPreparationStarted = CACurrentMediaTime()
            let now = CACurrentMediaTime()
            let uploadPixels = GridTextureUploadSizing.uploadPixels(
                slotSidePoints: slotSidePoints,
                backingScale: metalView.metalLayer.contentsScale,
                headroom: 1.15,
                floor: 64,
                cap: textureCache.maxTexturePixels
            )

            // Same universal composition sequence the macOS host uses (MetalGridFrameComposer), so a
            // streaming/rendering fix lands on both platforms at once. This host owns only the iOS plumbing:
            // the CAMetalLayer drawable, the level-aware upload size, the CADisplayLink, and the warm pump.
            let ids = MetalGridFrameComposer.classifyVisibility(
                slots: slots, flatUIDs: itemUIDs, viewportSize: viewportSize)
            let feed = thumbnailFeed
            let streamResult = MetalGridFrameComposer.stream(
                cache: textureCache,
                visibleIDs: ids.visible,
                overscanIDs: ids.overscan,
                effectiveUploadPixels: uploadPixels,
                allowUpgrade: allowUpgrade,
                now: now,
                hasImage: { feed?.memoryCGImage(for: $0) != nil },
                canRetry: { !(feed?.isKnownUnfetchable($0) ?? false) },
                needsSharperSource: { feed?.decodedNeedsSharperSource($0, forPixels: uploadPixels) ?? false },
                provideImage: { feed?.memoryCGImage(for: $0) },
                signposts: composeSignposts
            )
            if let metadataProvider {
                thumbnailOverlayResolver.noteVisible(
                    ids.visible.filter { textureCache.isResident($0) },
                    metadataProvider: metadataProvider
                )
            }
            let groups = MetalGridFrameComposer.buildGroups(
                slots: MetalGridFrameComposer.viewportDrawSlots(slots, viewportSize: viewportSize),
                flatUIDs: itemUIDs,
                cache: textureCache,
                displayMode: displayMode,
                cornerRadius: GridVisualConstants.thumbnailCornerRadius,
                decorations: productionDecorations(),
                now: now
            ).groups
            textureCache.evictToBudget()
            guard let acquisition = acquireDrawableTarget() else { return .noDrawable }
            let cpuPreparationMs = (acquisition.startedAt - cpuPreparationStarted) * 1000
            renderer.render(to: acquisition.target, viewportSize: viewportSize, groups: groups)

            let (missingVisible, ramReadyMissing) = missingRetryableTiles(
                in: ids.visible, isResident: textureCache.isResident)
            // The first visible thumbnail tells the shell to lift the loading UI onto the grid. Remaining
            // thumbnails continue loading behind the presented grid.
            // One-shot per content set; deferred to the next runloop tick so it never mutates observed shell
            // state during a SwiftUI update pass (renderNow can run inside updateUIView and layoutSubviews).
            if reportFirstContent, !firstContentReported, !ids.visible.isEmpty,
                ids.visible.contains(where: { textureCache.isResident($0) })
            {
                firstContentReported = true
                let generation = contentGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.contentGeneration == generation else { return }
                    self.onFirstContentReady?()
                }
            }
            // Warm still-missing visible tiles and the composer's warm list, which, when settled,
            // adds the sources of undersized resident textures whose RAM decode was evicted, so the upgrade can
            // re-decode and sharpen instead of the loop spinning on a pending upgrade it can never satisfy. Mirrors
            // the macOS host, which warms `result.warm`.
            scheduleWarmIfNeeded(warmUnion(missingVisible, streamResult.warm), pixelSize: uploadPixels)
            // Keep ticking only for work the render loop can make progress on this vsync: a visible tile
            // already decoded in RAM but held back by the per-frame upload budget (`uploadPending`), a soft-to-sharp
            // upgrade in flight, or a warm pass running. A visible tile that is still missing with no RAM image is
            // waiting on the network/disk crawl - the feed's arrival wake (`handleImagesAvailable`) re-arms the loop
            // when its bytes land, so we idle through that wait instead of spinning full frames the whole time.
            // RAM-decoded but not yet GPU-resident (the `ramHitGpuMissing` diagnostic): these tiles can fill on
            // the very next frames within the upload budget - a persistent count means upload-budget starvation.
            let uploadPending = ramReadyMissing > 0
            // Residency saturation means neither a deferred upload nor a deferred upgrade can make progress until the
            // streaming window changes (scroll/zoom, which re-arm on their own), so both are gated on it - matching
            // the macOS coordinator and avoiding a spin on placeholders that cannot fill this frame.
            let canMakeProgress = !textureCache.residencySaturatedThisFrame
            let hasPendingWork =
                forcePendingWork
                || warmInFlight
                || textureCache.hasActiveThumbnailReveal(in: ids.visible, now: now)
                || uploadBadgeAnimator.isAnimating(ids.visible, now: now)
                || ((uploadPending || streamResult.pendingVisibleQualityUpgrade) && canMakeProgress)
            perf.noteDraw(
                visible: ids.visible.count, missing: missingVisible.count,
                ramHitGpuMiss: ramReadyMissing, saturated: textureCache.residencySaturatedThisFrame,
                cache: textureCache, cpuPreparationMs: cpuPreparationMs,
                drawableWaitMs: acquisition.waitMs, frameBoundaryWaitMs: renderer.lastFrameBoundaryWaitMs,
                rendererEncodeMs: renderer.lastEncodeMs, gpuMs: renderer.lastCompletedGpuMs)
            return .drawn(hasPendingWork: hasPendingWork)
        }

        private func acquireDrawableTarget() -> (
            target: MetalGridDrawableTarget,
            startedAt: CFTimeInterval,
            waitMs: Double
        )? {
            let startedAt = CACurrentMediaTime()
            guard let target = MetalGridDrawableTarget(layer: metalView.metalLayer, clearColor: Self.gridClearColor)
            else {
                perf.noteDrawableWait((CACurrentMediaTime() - startedAt) * 1000)
                return nil
            }
            let waitMs = (CACurrentMediaTime() - startedAt) * 1000
            if let frame = activeDisplayFrame {
                let targetInterval = frame.targetTimestamp - frame.timestamp
                target.addPresentedHandler { [presentationTiming] presentedTime in
                    presentationTiming.note(
                        presentedTime: presentedTime,
                        targetTimestamp: frame.targetTimestamp,
                        targetInterval: targetInterval
                    )
                }
            }
            return (target, startedAt, waitMs)
        }

        /// The resolved grid geometry for the current viewport + active level, or nil when there is nothing to lay
        /// out. Built the same way `renderNow` builds it, so hit-testing and rendering never diverge.
        func currentGridContext() -> (engine: SquareTileGridEngine, level: Int, profile: GridLevelProfile)? {
            guard bounds.width > 0, !items.isEmpty else { return nil }
            let profile = currentProfile()
            let level = activeLevel(profile: profile)
            let engine = currentEngine(profile: profile)
            return (engine, level, profile)
        }

        var accessibilityItems: [PhotoItem] { items }

        func accessibilityFramePlan() -> GridFramePlan? {
            guard bounds.width > 0, bounds.height > 0, !items.isEmpty,
                let context = currentGridContext()
            else { return nil }
            return context.engine.framePlan(
                level: context.level,
                viewportSize: scrollView.bounds.size,
                scrollOffset: scrollView.contentOffset,
                overscan: 0,
                columnPhase: committedPhase
            )
        }

        /// Reports the date range of the photos between the top and bottom bars. Runs once per frame, so the
        /// label follows scrolling, pinch zoom and content changes; it formats only when the range changes.
        func publishVisibleDates() {
            let range = accessibilityFramePlan().flatMap { plan in
                TimelineVisibleDateRange(
                    items: items,
                    slots: plan.visibleSlots,
                    visibleTop: scrollView.contentOffset.y + safeAreaInsets.top,
                    visibleBottom: scrollView.contentOffset.y + bounds.height - safeAreaInsets.bottom)
            }
            guard range != visibleDateRange else { return }
            visibleDateRange = range
            let text = range.map(visibleDatesFormatter.string(for:))
            guard text != visibleDatesText else { return }
            visibleDatesText = text
            onVisibleDatesChanged?(text)
        }

        func invalidateAccessibilityElements() {
            accessibilityProvider.onOpen = { [weak self] item in self?.onOpenPhoto?(item) }
            accessibilityProvider.onToggleSelection = { [weak self] item in self?.onToggleSelection?(item) }
            accessibilityProvider.invalidate()
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            // A tap that merely halts a decelerating scroll must not also open/select a photo.
            guard gesture.state == .ended, !scrollView.isDecelerating, zoomTransaction == nil,
                let ctx = currentGridContext()
            else { return }
            // contentView spans the full content size at origin .zero, so its coordinate space IS the engine's
            // content space (y down, origin at the library top).
            let contentPoint = gesture.location(in: contentView)
            guard
                let slot = ctx.engine.hitTest(
                    contentPoint: contentPoint,
                    level: ctx.level,
                    width: bounds.width,
                    columnPhase: committedPhase
                ),
                slot.index >= 0, slot.index < items.count
            else { return }
            // In selection mode a tap toggles the cell (and never opens the viewer); otherwise it opens.
            if selectionMode {
                onToggleSelection?(items[slot.index])
            } else {
                onOpenPhoto?(items[slot.index])
            }
        }

        func item(at contentPoint: CGPoint) -> PhotoItem? {
            guard let context = currentGridContext(),
                let slot = context.engine.hitTest(
                    contentPoint: contentPoint,
                    level: context.level,
                    width: bounds.width,
                    columnPhase: committedPhase
                ),
                slot.index >= 0, slot.index < items.count
            else { return nil }
            return items[slot.index]
        }

        private func productionDecorations() -> MetalGridDecorations<PhotoUID> {
            let accent = SIMD4<Float>(Float(0x6D) / 255, Float(0x4A) / 255, Float(0xFF) / 255, 1)
            // One time for the whole frame, so every badge of the frame animates in step.
            let frameTime = CACurrentMediaTime()
            return MetalGridDecorations(
                accent: accent,
                accentGlyphColor: MetalGridGlyphColor(
                    red: Double(accent.x), green: Double(accent.y), blue: Double(accent.z), alpha: 1),
                selectionMode: selectionMode,
                // Outlines belong to selection mode only; normal browsing carries an empty set so a bare grid draws
                // just thumbnails + media overlays.
                selected: selectionMode ? selectedUIDs : [],
                favorites: [],
                overlay: { [thumbnailOverlayResolver] uid in thumbnailOverlayResolver.overlay(for: uid) },
                uploadBadgeFrame: { [uploadBadgeAnimator] uid, badge in
                    uploadBadgeAnimator.frame(for: uid, target: badge, now: frameTime)
                }
            )
        }
    }

    extension UIKitTimelineGridHostView: UIScrollViewDelegate {
        public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            scrollInputActive = true
            updateFeedInteractionState()
        }

        public func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if let lockedY = pinchLockedOffsetY {
                let clamped = min(max(lockedY, 0), maxContentOffsetY)
                if abs(scrollView.contentOffset.y - clamped) > 0.5 {
                    isApplyingProgrammaticScroll = true
                    scrollView.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)
                    isApplyingProgrammaticScroll = false
                }
                requestRender()
                invalidateAccessibilityElements()
                return
            }
            if !isApplyingProgrammaticScroll,
                scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
            {
                userHasScrolledTimeline = true
                resizeAnchorItemID = nil
                // Learn the travel direction from real finger scrolls only (drives the settled ahead-warm).
                let dy = scrollView.contentOffset.y - lastScrollY
                if abs(dy) > 1 { scrollDirectionDown = dy > 0 }
            }
            lastScrollY = scrollView.contentOffset.y
            if !isApplyingProgrammaticScroll { applyDeferredOrderIfOffscreen() }
            // Scroll deltas arrive faster than vsync - mark dirty only; the display link draws exactly once
            // per frame with whatever offset is current by then.
            perf.noteScrollEvent()
            requestRender()
            invalidateAccessibilityElements()
        }

        // Re-arm a render the moment the grid settles (drag ended without deceleration, deceleration finished, or a
        // programmatic scroll animation completed). `renderNow` then runs a frame with `isInteracting == false`, so
        // the shared soft-to-sharp upgrade path runs and undersized visible tiles sharpen.
        public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                scrollInputActive = false
                updateFeedInteractionState()
                requestRender()
            }
        }

        public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            scrollInputActive = false
            updateFeedInteractionState()
            requestRender()
        }

        public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            requestRender()
        }
    }

    extension UIKitTimelineGridHostView {
        func setPinchInputActive(_ active: Bool) {
            guard pinchInputActive != active else { return }
            pinchInputActive = active
            updateFeedInteractionState()
        }

        func updateFeedInteractionState() {
            let active = scrollInputActive || pinchInputActive
            guard active != reportedFeedInteractionActive else { return }
            reportedFeedInteractionActive = active
            thumbnailFeed?.setUserInteractionActive(active, owner: interactionOwner)
        }
    }

    extension UIKitTimelineGridHostView: UIGestureRecognizerDelegate {
        /// Let tap / pinch coexist with the scroll view's own pan (and each other) - a two-finger pinch and a
        /// one-finger scroll never contend, and a tap requires no movement. A swipe selection is exclusive, so a
        /// pinch cannot start while a range is being selected.
        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            other !== swipeSelection.pan && other !== swipeSelection.hold
        }
    }
#endif
