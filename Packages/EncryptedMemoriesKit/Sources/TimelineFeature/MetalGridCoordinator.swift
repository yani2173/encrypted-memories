import AppKit
import CoreGraphics
import GridCore
import MediaFeedCore
import MetalGridComposeCore
import MetalGridTextureAppKitAdapter
import MetalGridTextureCore
import MetalKit
import MetalRenderingCore
import PhotosCore
import TimelineCore
import simd

/// Bridges scroll position + geometry + texture cache + renderer for the Metal grid. It is the
/// `MTKView` delegate: every frame it reads the clip view's scroll origin, queries the visible square
/// slots from the canonical `SquareTileGridEngine`, uploads a bounded number of newly-available
/// thumbnails, draws the viewport, and emits diagnostics. Only items intersecting the (overscan-expanded)
/// visible rect are ever touched - never the whole library.
@MainActor
final class MetalGridCoordinator: NSObject, MTKViewDelegate {
    private let renderer: MetalGridRenderer
    private let cache: MetalGridTextureCache<PhotoUID>
    private var memoryPressureRegistration: MemoryPressureRegistration?
    private var dataSource: MetalGridDataSource
    private let budget: MetalGridBudget
    private(set) var gridProfile: GridLevelProfile
    private var fillOrder: GridFillOrder = .newestBottomTrailing

    /// Fired once for each installed data source when its first visible frame is fully populated.
    var onContentReady: (() -> Void)?
    private var contentReadyReported = false
    private var firstContentReadyLogged = false
    /// Notifies the shell while the grid is presenting a live resize.
    var liveResizeChanged: ((Bool) -> Void)?
    /// One-shot cold-start `[FirstContent]` trace state for the first on-screen frame with real visible cells.
    private var firstContentTraced = false
    private var firstGridFrameAt: CFTimeInterval = 0

    var onRequestRedraw: (() -> Void)?
    private(set) var lastRenderOutcome: GridRenderOutcome = .skippedNoSurface

    weak var clipView: NSClipView?
    weak var metalView: MTKView?

    var level: Int {  // clamped to the injected engine ladder in didSet
        didSet {
            level = engine.clampLevel(level)
            if level != oldValue { onContentSizeChange?(contentSize()) }
        }
    }

    // MARK: - Canonical geometry engine
    //
    // `SquareTileGridEngine` owns slot geometry, metrics, content size, visible queries, hit testing, and
    // anchor-preserving zoom plans. The coordinator converts its frame plans into Metal draw groups.
    private(set) var engine: SquareTileGridEngine

    // MARK: - Live zoom transaction
    //
    // A live pinch captures one `GridZoomTransaction` at gesture start. Its anchor-relative layout keeps the
    // row under the cursor stable while the host moves through the continuous level range.
    private var zoomTransaction: GridZoomTransaction?
    private var zoomTransactionLevel: CGFloat = 0
    /// True while a live focus-row zoom is in flight (the host freezes scroll while this holds).
    var isZoomingLive: Bool { zoomTransaction != nil }
    /// The live continuous level position (for the host's snap-on-release).
    var liveZoomLevel: CGFloat { zoomTransactionLevel }

    // MARK: - Single-presentation-lattice transition
    //
    // The transition layer consumes frame plans without changing geometry, fitting, or resize state. It is
    // attempted for eligible normal-level clicks and pinches; invalid geometry uses the stable fallback.
    let gridTransition = GridTransitionController(telemetrySink: { event in
        PhotoDiagnostics.shared.emit(event.name, event.fields)
    })
    private var transitionPrevNow: CFTimeInterval = 0
    private var selectedFlatIndices: Set<Int> { Set(selectedUIDs.compactMap { indexByUID[$0] }) }

    // Live pinch: each adjacent segment is a `.pinch` plan driven by the host's scrub driver. Nothing is
    // committed until release; segments rebuild when the gesture crosses a detent.
    //
    // The start detent uses the current on-screen state. Other detents use cursor-aligned phase and anchored
    // scroll so the item under the cursor remains stable across the chain.
    private var pinchStartLevel: Int = 0
    private var pinchStartPhase: Int?
    private var pinchStartScrollY: CGFloat = 0
    /// The segment currently built into `gridTransition` (source = denser end, target = larger-tile end).
    private(set) var pinchSegmentSource: Int?
    private(set) var pinchSegmentTarget: Int?

    // Overview dissolves blend two complete settled grids in the offscreen compositor. They are separate from
    // the per-cell transition and are used at overview boundaries and for discrete +/- clicks.
    private(set) var overviewDissolve: OverviewLayerDissolvePlan?
    var isOverviewClickDissolving: Bool { overviewClickDissolveActive }
    private var overviewClickDissolveActive = false
    private var overviewClickDissolveStart: CFTimeInterval = 0
    private let overviewClickDissolveDuration: CFTimeInterval = 0.18

    // Settled timelines use bottom-right anchoring. The live transaction can use a cursor-aligned phase, but
    // the settled engine restores its canonical fill order after the commit.

    // MARK: - Commit bridge
    //
    // The live transaction and settled grid may use different column phases. The short geometry-only bridge
    // interpolates visible item rectangles between those plans, preserving identity without a snap or crossfade.
    private var bridgeTransaction: GridZoomTransaction?
    private var bridgeLevel = 0
    private var bridgeScrollY: CGFloat = 0
    /// Normalized commit progress advanced by the display link.
    var commitBridgeProgress: CGFloat = 0
    /// Measured at release for diagnostics + the `end` log.
    private var bridgeDelta: GridZoomCommitDelta?
    var isCommitBridging: Bool { bridgeTransaction != nil }

    // MARK: - Scroll rebase bridge
    //
    // A commit or content-shrinking zoom-out can leave the camera outside the legal scroll range. The settled
    // render interpolates the engine-derived Y values and ends at the clamped value.
    private var rebaseActive = false
    private var rebaseFromY: CGFloat = 0
    private var rebaseToY: CGFloat = 0
    private var rebaseStart: CFTimeInterval = 0
    var isScrollRebasing: Bool { rebaseActive }

    /// Arm a scroll-rebase: the settled grid slides from `fromY` (gesture/anchored) to `toY` (legal clamped).
    /// No-op (returns false) when the delta is imperceptible - the caller then settles instantly.
    @discardableResult
    func beginScrollRebase(fromY: CGFloat, toY: CGFloat) -> Bool {
        guard GridScrollRebase.shouldArm(fromY: fromY, toY: toY) else {
            rebaseActive = false
            return false
        }
        rebaseFromY = fromY
        rebaseToY = toY
        rebaseStart = CACurrentMediaTime()
        rebaseActive = true
        requestRedraw()
        return true
    }

    // MARK: - Camera column phase
    //
    // During a live zoom, the phase places the anchor in the cursor's column and persists across settled
    // queries. A nil phase selects the canonical bottom-right fill order.
    private var committedPhase: Int?
    func currentPhase() -> Int? { committedPhase }
    /// Reset to the canonical bottom-right phase (newest in the corner). Called on bottom-pin / data rebuild.
    func resetCommittedPhase() {
        committedPhase = nil
        requestRedraw()
    }

    // The current gesture's anchor identity, for the `[GridZoomAnchor]` trace (pinch = cursor item; +/- = the
    // viewport-centre item). Used to assert the item under the anchor survives the whole zoom.
    private var gestureTrigger: GridZoomTrigger = .pinch
    private var gestureCursorVP: CGPoint = .zero
    private var gestureAnchorIndex: Int?

    // MARK: - Content display mode
    //
    // The toggle changes only thumbnail fitting. It does not change slot geometry, content size, hit testing,
    // anchor state, or phase. Normal levels keep the user's preference; overview levels use square fill.
    private(set) var preferredNormalLevelContentMode: TileContentDisplayMode = .aspectFitInsideSquare
    private var contentModeTransition:
        (from: TileContentDisplayMode, to: TileContentDisplayMode, startedAt: CFTimeInterval)?
    private let contentModeTransitionDuration: CFTimeInterval = 0.22

    /// The mode actually used to fit content at `level`: the preference where the level supports it, else
    /// squareFillCrop (the only mode the overview levels offer).
    func effectiveDisplayMode(for level: Int) -> TileContentDisplayMode {
        engine.effectiveContentMode(preferred: preferredNormalLevelContentMode, level: level)
    }
    var effectiveDisplayMode: TileContentDisplayMode { effectiveDisplayMode(for: level) }

    /// Returns whether a level supports both thumbnail content modes.
    func aspectToggleAvailable(for level: Int) -> Bool { engine.contentModeToggleAvailable(level: level) }
    var aspectToggleAvailable: Bool { aspectToggleAvailable(for: level) }

    /// Set the normal-level content-mode preference. This changes only the next frame's thumbnail fit.
    func setPreferredNormalLevelContentMode(_ mode: TileContentDisplayMode) {
        guard mode != preferredNormalLevelContentMode else { return }
        let previous = effectiveDisplayMode
        preferredNormalLevelContentMode = mode
        let current = effectiveDisplayMode
        if previous != current {
            contentModeTransition = (previous, current, CACurrentMediaTime())
        }
        requestRedraw()
    }

    /// Flip the normal-level content-mode preference.
    func toggleContentMode() {
        setPreferredNormalLevelContentMode(
            preferredNormalLevelContentMode == .squareFillCrop ? .aspectFitInsideSquare : .squareFillCrop)
    }

    /// Pushed (throttled) so the SwiftUI HUD can mirror live stats.
    var onHUD: ((MetalGridHUD) -> Void)?
    /// Called when the content size changes (level / width) so the host can resize the document view.
    var onContentSizeChange: ((CGSize) -> Void)?

    // Diagnostics state
    private var lastHUDPushDetent: CFTimeInterval = 0
    private var lastPerfDiagnosticsLog: CFTimeInterval = 0
    private var lastCommitFrameLog: CFTimeInterval = 0

    /// True when some visible cell still lacks a real texture - the host keeps ticking redraws while this
    /// holds (so placeholders swap to thumbnails without needing a scroll), and goes idle once false.
    /// Forced false while the resident texture budget is saturated: those placeholders cannot fill until
    /// the window changes, and scroll/zoom/image-arrival all trigger their own redraws, so ticking would
    /// only busy-spin the display link.
    private(set) var hasPendingVisibleThumbnails = false

    // MARK: - Level-aware upload sizing
    //
    // Thumbnails upload at the on-screen slot's native pixel size (slot points × display backing scale).
    // Sparse levels saturate at the adapter's `maxTexturePixels`. The sizing math lives in
    // `GridCore.GridTextureUploadSizing`; this host supplies the current slot side and backing scale.

    /// Live display backing scale (drawable px per point), refreshed from the MTKView each frame: 2 on a Retina
    /// display, 1 on a non-Retina external monitor. 2 is a safe default until the first `draw(in:)`.
    private var backingScale: CGFloat = 2
    /// Supersampling headroom over a slot's native pixel size when choosing upload resolution. > 1 spends a
    /// little VRAM to cut minification shimmer on the mip-less grid textures; at sparse levels the result
    /// saturates at `maxTexturePixels` anyway, so those keep full quality.
    private static let uploadPixelsHeadroom: CGFloat = 1.25
    /// Never upload a thumbnail below this, even for a physically tiny dense-overview slot - a crispness floor.
    private static let uploadPixelsFloor = 96

    /// The effective upload cap for the current settled level: native slot pixels clamped to the adapter cap.
    private func effectiveUploadPixels() -> Int {
        let (_, slotSide, _, _) = engine.resolvedMetrics(level: level, width: layoutWidth)
        return GridTextureUploadSizing.uploadPixels(
            slotSidePoints: slotSide,
            backingScale: backingScale,
            headroom: Self.uploadPixelsHeadroom,
            floor: Self.uploadPixelsFloor,
            cap: cache.maxTexturePixels
        )
    }

    /// Wires the composer's upload/upgrade work into this host's `Grid` signpost category so the
    /// `streamTextures.upload` / `streamTextures.upgrade` Instruments intervals survive the extraction.
    private lazy var composeSignposts = MetalGridComposeSignposts(
        uploadInterval: { PhotoPerformanceSignposts.grid.interval("streamTextures.upload", $0) },
        upgradeInterval: { PhotoPerformanceSignposts.grid.interval("streamTextures.upgrade", $0) }
    )

    init?(
        device: MTLDevice, dataSource: MetalGridDataSource, budget: MetalGridBudget = .default,
        gridProfile: GridLevelProfile, fillOrder: GridFillOrder = .newestBottomTrailing,
        memoryGovernor: MemoryPressureGovernor? = nil
    ) {
        let texturePolicy = AppKitMetalGridTexturePolicies.policy(budget: budget)
        guard let renderer = MetalGridRenderer(device: device, clearColor: MetalGridPalette.clearColor),
            let cache = AppKitMetalGridTextureCacheFactory.makeCache(
                device: device,
                policy: texturePolicy
            ) as MetalGridTextureCache<PhotoUID>?
        else { return nil }
        if renderer.compositePipelineUnavailable {
            PhotoDiagnostics.shared.emit("MetalGridRenderer", ["compositePipeline": "unavailable"])
        }
        self.renderer = renderer
        self.cache = cache
        self.dataSource = dataSource
        self.budget = budget
        self.gridProfile = gridProfile
        self.fillOrder = fillOrder
        self.level = gridProfile.defaultLevel
        self.engine = SquareTileGridEngine(
            sectionCounts: dataSource.sectionCounts, profile: gridProfile,
            fillOrder: fillOrder)
        super.init()
        rebuildIndex()
        // Register the GPU texture cache with the injected memory governor (nil in tests). Keep the token
        // until coordinator teardown so a discarded coordinator cannot leave a stale responder behind.
        memoryPressureRegistration = memoryGovernor?.register { [weak cache] tier in
            cache?.setResidencyPressureScale(tier.budgetScale)
        }
    }

    deinit {
        let registration = memoryPressureRegistration
        Task { @MainActor in
            registration?.end()
        }
    }

    func setDataSource(_ newSource: MetalGridDataSource, preservingColumnPhase: Bool = false) {
        contentReadyReported = false
        dataSource = newSource
        newSource.updateUploadBadges(uploadBadges)
        rebuildIndex(preservingColumnPhase: preservingColumnPhase)
        onContentSizeChange?(contentSize())
        requestRedraw()
    }

    func setFillOrder(_ newFillOrder: GridFillOrder) {
        guard fillOrder != newFillOrder else { return }
        fillOrder = newFillOrder
        rebuildIndex()
        onContentSizeChange?(contentSize())
        requestRedraw()
    }

    var totalItems: Int { dataSource.flatUIDs.count }
    var orderedUIDs: [PhotoUID] { dataSource.flatUIDs }
    var gridProfileID: String { gridProfile.id }

    func setUserInteractionActive(_ active: Bool, owner: ThumbnailInteractionOwner) {
        dataSource.setUserInteractionActive(active, owner: owner)
    }

    @discardableResult
    func applyGridProfile(
        _ newProfile: GridLevelProfile,
        oldFrame: CGRect,
        newFrame: CGRect,
        oldScrollY: CGFloat,
        wasBottomPinned: Bool,
        targetCommittedPhase: Int? = nil,
        levelMapping: GridProfileRebaseLevelMapping = .closestVisualMatch
    ) -> GridProfileRebaseResult? {
        guard newProfile.id != gridProfile.id else { return nil }
        var targetEngine = SquareTileGridEngine(
            sectionCounts: dataSource.sectionCounts, profile: newProfile,
            fillOrder: fillOrder)
        targetEngine.topInset = topBarInset
        let result = engine.rebasedScrollOffsetForProfileChange(
            GridProfileRebaseInput(
                targetEngine: targetEngine,
                oldViewportFrame: oldFrame,
                newViewportFrame: newFrame,
                oldScrollY: oldScrollY,
                sourceLevel: level,
                sourceCommittedPhase: currentPhase(),
                targetCommittedPhase: targetCommittedPhase,
                wasBottomPinned: wasBottomPinned,
                levelMapping: levelMapping
            ))

        gridProfile = newProfile
        engine = targetEngine
        committedPhase = result.targetCommittedPhase
        level = result.targetLevel
        onContentSizeChange?(contentSize())
        requestRedraw()
        return result
    }

    // MARK: - Production decorations and selection state

    /// When true, selection outlines plus favorite/check and duration/RAW overlays are drawn for visible cells.
    var decorationsEnabled = false
    private(set) var selectedUIDs: Set<PhotoUID> = []
    private(set) var favoriteUIDs: Set<PhotoUID> = []
    private(set) var uploadBadges = PendingUploadBadges.empty
    private var contentEpochs = PendingContentEpochTracker()
    private var handovers = PendingHandoverTracker()
    private let uploadBadgeAnimator = GridUploadBadgeAnimator<PhotoUID>()
    /// The last frame asked the feed for thumbnails; the first frame without demand tells the feed once.
    private var hasVisibleDemand = false
    private(set) var selectionMode = false
    private var indexByUID: [PhotoUID: Int] = [:]

    // Avoid redraws for unchanged selection and favorite state.
    func setSelection(_ uids: Set<PhotoUID>) {
        guard uids != selectedUIDs else { return }
        selectedUIDs = uids
        requestRedraw()
    }
    func setFavorites(_ uids: Set<PhotoUID>) {
        guard uids != favoriteUIDs else { return }
        favoriteUIDs = uids
        requestRedraw()
    }
    /// The grid left the screen: local downloads it asked for stop, and the next visible frame asks again.
    func retireLocalDemand() {
        hasVisibleDemand = false
        dataSource.retireLocalDemand()
    }

    /// The data source redraws when a badge changes.
    func setUploadBadges(_ badges: PendingUploadBadges) {
        guard badges != uploadBadges else { return }
        uploadBadges = badges
        dataSource.updateUploadBadges(badges)
        for handover in handovers.newHandovers(in: badges.handovers) {
            cache.adoptTexture(from: handover.local, to: handover.remote)
            uploadBadgeAnimator.adopt(from: handover.local, to: handover.remote)
        }
        let changed = contentEpochs.changes(in: badges.contentEpochs)
        if !changed.isEmpty {
            cache.markStale(changed)
            requestRedraw()
        }
    }
    func setSelectionMode(_ on: Bool) {
        guard on != selectionMode else { return }
        selectionMode = on
        requestRedraw()
    }
    func requestRedraw() { onRequestRedraw?() }

    private func rebuildIndex(preservingColumnPhase: Bool = false) {
        var map: [PhotoUID: Int] = [:]
        map.reserveCapacity(dataSource.flatUIDs.count)
        for (i, uid) in dataSource.flatUIDs.enumerated() { map[uid] = i }
        indexByUID = map
        // Rebuild the canonical engine from the new section structure.
        engine = SquareTileGridEngine(
            sectionCounts: dataSource.sectionCounts, profile: gridProfile,
            fillOrder: fillOrder)
        engine.topInset = topBarInset  // A new engine starts without the toolbar inset.
        if !preservingColumnPhase { committedPhase = nil }  // A prior phase may not fit changed membership.
    }

    func flatIndex(forUID uid: PhotoUID) -> Int? { indexByUID[uid] }
    func uid(atFlatIndex index: Int) -> PhotoUID? {
        let uids = dataSource.flatUIDs
        return (index >= 0 && index < uids.count) ? uids[index] : nil
    }

    /// The photo cell + its flat index under a content-space point (for click/selection).
    func hitTestCell(contentPoint: CGPoint) -> (flatIndex: Int, uid: PhotoUID)? {
        let width = layoutWidth
        guard width > 1,
            let slot = engine.hitTest(
                contentPoint: contentPoint, level: level, width: width, columnPhase: currentPhase()),
            let uid = uid(atFlatIndex: slot.index)
        else { return nil }
        return (slot.index, uid)
    }

    /// Drag-out owns only the visible photo interior; its edge remains available for marquee.
    func hitTestDragOut(contentPoint: CGPoint) -> (flatIndex: Int, uid: PhotoUID)? {
        guard let hit = hitTestCell(contentPoint: contentPoint),
            let slot = cellRect(flatIndex: hit.flatIndex)
        else { return nil }
        let image = thumbnailImage(for: hit.uid)
        let pixels = image.map { CGSize(width: $0.width, height: $0.height) } ?? slot.size
        let visible = TileContentFitter.fit(
            slotRect: slot, mediaPixelSize: pixels, displayMode: effectiveDisplayMode
        ).contentRect
        return GridDragIntentPolicy.startsDragOut(at: contentPoint, visiblePhotoRect: visible) ? hit : nil
    }

    /// The content-space rectangle of the cell at a flat index (for drag ghosts). Nil when the
    /// engine has no layout for that index yet.
    func cellRect(flatIndex: Int) -> CGRect? {
        let width = layoutWidth
        guard width > 1 else { return nil }
        return engine.slotRect(flatIndex: flatIndex, level: level, width: width, columnPhase: currentPhase())
    }

    /// The decoded thumbnail for a uid (drag ghost imagery). Nil while the tile is not yet cached.
    func thumbnailImage(for uid: PhotoUID) -> CGImage? {
        dataSource.image(for: uid)
    }

    /// The UIDs whose cells intersect a content-space rect - the marquee (drag-rectangle) selection set.
    func uids(intersecting contentRect: CGRect) -> Set<PhotoUID> {
        let width = layoutWidth
        guard width > 1 else { return [] }
        let slots = engine.slots(intersecting: contentRect, level: level, width: width, columnPhase: currentPhase())
        return Set(slots.compactMap { uid(atFlatIndex: $0.index) })
    }

    var levelCount: Int { engine.levelCount }
    func clampLevel(_ l: Int) -> Int { engine.clampLevel(l) }

    // MARK: - Live focus-row zoom transaction (driven by the host's trackpad pinch)

    /// Begin a live zoom anchored at the item under (or nearest to) the cursor. `viewportPoint` is where to
    /// hold it (the cursor in viewport coords). The engine captures the transaction; the row under the cursor
    /// is then preserved as the level position changes.
    func beginLiveZoom(cursorContentPoint: CGPoint, viewportPoint: CGPoint) {
        let width = layoutWidth
        // Resolve the item shown under the cursor in the current phased grid.
        let hovered = engine.hitTest(
            contentPoint: cursorContentPoint, level: level, width: width, columnPhase: currentPhase())?.index
        zoomTransaction = engine.beginZoomTransaction(
            cursorContentPoint: cursorContentPoint,
            viewportPoint: viewportPoint, level: level, width: width,
            columnPhase: currentPhase())
        zoomTransactionLevel = CGFloat(level)
        // Capture the gesture-start state; the start detent uses this frame in every segment.
        pinchStartLevel = level
        pinchStartPhase = currentPhase()
        pinchStartScrollY = clipView?.bounds.origin.y ?? 0
        pinchSegmentSource = nil
        pinchSegmentTarget = nil
        gestureTrigger = .pinch
        gestureCursorVP = viewportPoint
        gestureAnchorIndex = zoomTransaction?.anchorGlobalIndex
        GridZoomAnchorLog.begin(
            trigger: .pinch, cursorViewportPoint: viewportPoint, cursorContentPoint: cursorContentPoint,
            hoveredIndexAtBegin: hovered, transactionAnchorIndex: gestureAnchorIndex, level: level)
        if let tx = zoomTransaction {
            GridZoomCommitLog.begin(
                sourceLevel: level, anchorGlobalIndex: tx.anchorGlobalIndex,
                anchorViewportPoint: tx.anchorViewportPoint,
                focusRow: tx.frame(continuousLevel: CGFloat(level), viewportSize: layoutViewportSize, overscan: 0)
                    .focusRow)
        }
        requestRedraw()
    }

    /// Returns the item under a viewport point in the current settled grid.
    func indexUnderCursorViewport(_ vp: CGPoint) -> Int? {
        let width = layoutWidth
        guard width > 1 else { return nil }
        let scrollY = clipView?.bounds.origin.y ?? 0
        return engine.hitTest(
            contentPoint: CGPoint(x: vp.x, y: vp.y + scrollY), level: level, width: width, columnPhase: currentPhase())?
            .index
    }

    /// Update the live continuous level position (fractional = mid-pinch) from a raw pinch level. Past the
    /// largest detent (raw level < 0) the visual level carries a bounded elastic overshoot - the rubber-band -
    /// instead of being hard-clamped to 0. The committed level stays clamped to valid detents separately.
    func updateLiveZoom(continuousLevel x: CGFloat) {
        guard zoomTransaction != nil else { return }
        zoomTransactionLevel = GridLiveZoomBounds.visualLevel(rawLevel: x, levelCount: engine.levelCount)
        requestRedraw()
    }

    /// Set the live visual level directly (already resolved, e.g. by the release spring-back), clamped to the
    /// safe live range `[-maxOverZoom, densest]`. Distinct from `updateLiveZoom`, which resists a raw level.
    func setLiveVisualLevel(_ v: CGFloat) {
        guard zoomTransaction != nil else { return }
        zoomTransactionLevel = GridLiveZoomBounds.clampVisual(v, levelCount: engine.levelCount)
        requestRedraw()
    }

    /// Begin the commit bridge: capture the live transaction as the bridge's source, rebase the scroll offset
    /// from the anchor (clamped to content), commit the settled `finalLevel`, and clear the live transaction.
    /// Returns the clamped target scroll position for the bridge.
    /// nil only if no live transaction. Logs the `[GridZoomCommit] release` seam measurement.
    func beginCommitBridge(finalLevel: Int) -> CGFloat? {
        guard let tx = zoomTransaction else { return nil }
        let width = layoutWidth
        let lv = engine.clampLevel(finalLevel)
        // Place the anchor in the cursor's target column. The committed phase is used by the first post-commit
        // frame and by subsequent settled queries.
        let metrics = engine.resolvedMetrics(level: lv, width: width)
        let desiredColumn = engine.cursorColumn(viewportX: tx.anchorViewportPoint.x, level: lv, width: width)
        let phase = engine.columnPhase(
            forItem: tx.anchorGlobalIndex, targetColumn: desiredColumn, level: lv, width: width)
        committedPhase = phase
        let rawY = engine.anchoredScrollOffset(
            flatIndex: tx.anchorGlobalIndex, localFraction: tx.anchorLocalFraction,
            viewportPoint: tx.anchorViewportPoint, level: lv, width: width, columnPhase: phase
        ).y
        let content = engine.contentSize(level: lv, width: width, columnPhase: phase)
        let clipH = clipView?.bounds.height ?? metalView?.bounds.height ?? 0
        let clampedY = min(max(0, rawY), max(0, content.height - clipH))
        let overscan = budget.overscanFraction * viewportSize.height
        let delta = engine.commitDelta(
            transaction: tx, targetLevel: lv, viewportSize: layoutViewportSize, columnPhase: phase)
        // The maximum horizontal move any matched index would undergo (with the phase, a uniform sub-cell residual).
        let maxMove = GridZoomCommitBridge.maxMatchedIndexMoveX(
            transaction: tx, engine: engine, targetLevel: lv,
            viewportSize: layoutViewportSize, scrollY: clampedY, overscan: overscan, columnPhase: phase)
        let tolerance = GridZoomCommitBridge.tolerance(targetPitch: metrics.pitch)
        let bridgeIt = maxMove <= tolerance  // bridge only a tiny sub-cell residual; else commit instantly

        // Diagnostics.
        let selectedIdx = selectedUIDs.count == 1 ? selectedUIDs.first.flatMap { indexByUID[$0] } : nil
        let anchorDeltaColumns = metrics.pitch > 0 ? Int((delta.anchorDelta.width / metrics.pitch).rounded()) : 0
        GridZoomCommitLog.release(
            anchorGlobalIndex: tx.anchorGlobalIndex, hoveredGlobalIndex: tx.anchorGlobalIndex,
            selectedGlobalIndex: selectedIdx, targetLevel: lv, targetColumns: metrics.columns,
            desiredCursorColumn: desiredColumn, computedColumnPhase: phase, delta: delta,
            anchorDeltaColumns: anchorDeltaColumns)
        GridZoomCommitLog.bridge(
            maxMatchedIndexMovePx: maxMove,
            maxMatchedIndexMoveColumns: metrics.pitch > 0 ? Double(maxMove / metrics.pitch) : 0,
            largeMoveRejected: !bridgeIt)
        // The transaction pins the anchor at the cursor, so the item under the cursor before commit IS the anchor.
        GridZoomAnchorLog.release(
            targetLevel: lv, cursorViewportPoint: tx.anchorViewportPoint,
            indexUnderCursorBeforeCommit: tx.anchorGlobalIndex, transactionAnchorIndex: tx.anchorGlobalIndex,
            committedPhase: phase, targetScrollY: clampedY, bridgeWillRun: bridgeIt)

        level = lv  // settled metrics/content for the target (didSet recomputes content size)
        zoomTransaction = nil
        if bridgeIt {
            bridgeTransaction = tx
            bridgeLevel = lv
            bridgeScrollY = clampedY
            bridgeDelta = delta
            commitBridgeProgress = 0
        } else {
            // Large residuals commit directly to the phased plan.
            bridgeTransaction = nil
            GridZoomCommitLog.end(settledUsesCommittedPhase: committedPhase == phase)
        }
        requestRedraw()
        return clampedY
    }

    /// Override the bridge's settled scroll Y (e.g. when the host pins to the bottom instead of the rebased Y).
    func setCommitBridgeScrollY(_ y: CGFloat) { bridgeScrollY = y }

    /// Rebase the viewport after a resize. Level, phase, mode, columns, and gap remain unchanged; slot size and
    /// content height use the new width. The host applies the returned scroll before the next frame.
    private var lastResizeDiagTime: Date = .distantPast
    /// Rebase using old and new screen-space viewport frames so the engine can preserve the moved-edge anchor.
    func rebaseForViewportChange(
        oldFrame: CGRect, newFrame: CGRect, oldScrollY: CGFloat,
        wasBottomPinned: Bool
    ) -> GridViewportResizeResult? {
        let count = totalItems
        guard count > 0 else { return nil }
        let lvl = level
        let phase = currentPhase()
        let delta = GridViewportResizeDelta(old: oldFrame, new: newFrame)
        let anchorFractionY = resizeAnchorFraction(for: delta)
        let input = GridViewportResizeInput(
            oldViewportFrame: oldFrame, newViewportFrame: newFrame, oldScrollY: oldScrollY,
            level: lvl, committedPhase: phase, itemCount: count,
            wasBottomPinned: wasBottomPinned,
            anchorFractionY: anchorFractionY)
        let t0 = Date()
        let r = engine.rebasedScrollOffsetForViewportChange(input)  // cheap: 1 anchorItem + 1 slotRect
        let layoutMs = Date().timeIntervalSince(t0) * 1000
        // Throttle diagnostics during live drags because layout runs once per frame.
        let now = Date()
        if now.timeIntervalSince(lastResizeDiagTime) > 0.33 {
            lastResizeDiagTime = now
            let reason: String =
                wasBottomPinned
                ? "bottomPinned"
                : (delta.widthChanged && delta.movedLeftEdge && !delta.heightChanged)
                    ? "sidebarWidth"
                    : (delta.heightChanged && delta.movedTopEdge && !delta.movedBottomEdge)
                        ? "windowHeightTopEdge"
                        : (delta.heightChanged && delta.movedBottomEdge && !delta.movedTopEdge)
                            ? "windowHeightBottomEdge"
                            : (delta.widthChanged && !delta.heightChanged)
                                ? "windowWidth"
                                : delta.heightChanged ? "windowResizeUnknownEdge" : "unknown"
            let oldVP = CGSize(width: max(oldFrame.width, 1), height: max(oldFrame.height, 0))
            let newVP = CGSize(width: max(newFrame.width, 1), height: max(newFrame.height, 0))
            let mOld = engine.resolvedMetrics(level: lvl, width: oldVP.width)
            let mNew = engine.resolvedMetrics(level: lvl, width: newVP.width)
            let oldContent = engine.contentSize(level: lvl, width: oldVP.width, columnPhase: phase)
            let visBefore = Set(
                engine.framePlan(
                    level: lvl, viewportSize: oldVP, scrollOffset: CGPoint(x: 0, y: oldScrollY), overscan: 0,
                    columnPhase: phase
                ).visibleSlots.map(\.index))
            let visAfter = Set(
                engine.framePlan(
                    level: lvl, viewportSize: newVP, scrollOffset: CGPoint(x: 0, y: r.newScrollY), overscan: 0,
                    columnPhase: phase
                ).visibleSlots.map(\.index))
            let anchorVY: CGFloat = newVP.height * r.anchorFractionY  // the normalized anchor's viewport y
            GridResizeLog.begin(
                reason: reason, oldFrame: oldFrame, newFrame: newFrame, delta: delta, level: lvl, phase: phase,
                wasBottomPinned: wasBottomPinned, result: r, anchorViewportY: anchorVY,
                oldScrollY: oldScrollY, oldContentSize: oldContent)
            GridResizeLog.end(result: r, anchorViewportYAfter: anchorVY)
            GridResizeLog.validation(
                visibleBefore: visBefore.count, visibleAfter: visAfter.count,
                visibleOverlap: visBefore.intersection(visAfter).count,
                columnsBefore: mOld.columns, columnsAfter: mNew.columns,
                slotSideBefore: mOld.slotSide, slotSideAfter: mNew.slotSide, gapBefore: mOld.gap, gapAfter: mNew.gap)
            // Metrics and content size are recomputed only when the width changes.
            MetalGridPerfLog.resizeFrame(
                layoutMs: layoutMs, visibleSlotCount: visAfter.count, renderQuadCount: visAfter.count,
                textureUploadCount: cache.uploadsThisFrame, widthChanged: delta.widthChanged,
                heightChanged: delta.heightChanged, metricsRecomputed: delta.widthChanged,
                contentSizeRecomputed: delta.widthChanged)
        }
        return r
    }

    /// Runtime policy for resize/sidebar animation: hold the stationary vertical edge when one is obvious.
    /// Width-only changes (window side drag / sidebar reveal) preserve the viewport top so resizing clips or
    /// reveals instead of re-centering the camera every frame. The engine remains generic; this is host policy.
    private func resizeAnchorFraction(for delta: GridViewportResizeDelta) -> CGFloat {
        if delta.heightChanged {
            if delta.movedBottomEdge && !delta.movedTopEdge { return 0 }
            if delta.movedTopEdge && !delta.movedBottomEdge { return 1 }
            return 0.5
        }
        return 0
    }

    /// Ends the bridge and resumes settled rendering at the committed level.
    func endCommitBridge() {
        GridZoomCommitLog.end(settledUsesCommittedPhase: committedPhase != nil)
        bridgeTransaction = nil
        bridgeDelta = nil
        logPostCommitAnchor()
        requestRedraw()
    }

    /// `[GridZoomAnchor] postCommit`: probe the item under the gesture cursor in the now-settled grid (current
    /// scroll and committed phase). Call after applying the commit scroll.
    func logPostCommitAnchor() {
        GridZoomAnchorLog.postCommit(
            cursorViewportPoint: gestureCursorVP,
            indexUnderCursorAfterCommit: indexUnderCursorViewport(gestureCursorVP),
            transactionAnchorIndex: gestureAnchorIndex ?? -1,
            scrollY: clipView?.bounds.origin.y ?? 0, phase: currentPhase())
    }

    /// A discrete +/- (or programmatic) level change that keeps the item under `anchorContentPoint` at the
    /// same viewport point (zoom toward the cursor) and lands it in the cursor's column (cursor-aligned phase),
    /// so +/- zoom is also fly-free. Returns the scroll Y to apply; nil if no item resolvable.
    func settleScrollOffsetY(
        toLevel newLevel: Int, anchorContentPoint: CGPoint, viewportPoint: CGPoint,
        trigger: GridZoomTrigger = .toolbarPlus
    ) -> CGFloat? {
        let width = layoutWidth
        guard
            let a = engine.anchorItem(
                nearContentPoint: anchorContentPoint, level: level, width: width, columnPhase: currentPhase())
        else {
            level = engine.clampLevel(newLevel)
            return nil
        }
        // +/- anchors at the viewport centre (passed by the host); record it for the anchor trace.
        gestureTrigger = trigger
        gestureCursorVP = viewportPoint
        gestureAnchorIndex = a.flatIndex
        GridZoomAnchorLog.begin(
            trigger: trigger, cursorViewportPoint: viewportPoint, cursorContentPoint: anchorContentPoint,
            hoveredIndexAtBegin: a.flatIndex, transactionAnchorIndex: a.flatIndex, level: level)
        let lv = engine.clampLevel(newLevel)
        let desiredColumn = engine.cursorColumn(viewportX: viewportPoint.x, level: lv, width: width)
        committedPhase = engine.columnPhase(forItem: a.flatIndex, targetColumn: desiredColumn, level: lv, width: width)
        level = lv
        return engine.anchoredScrollOffset(
            flatIndex: a.flatIndex, localFraction: a.localFraction,
            viewportPoint: viewportPoint, level: lv, width: width, columnPhase: committedPhase
        ).y
    }

    /// A photo's cell rect in content coordinates at the current level/width (nil if unknown).
    func cellContentRect(forUID uid: PhotoUID) -> CGRect? {
        guard let index = indexByUID[uid] else { return nil }
        guard let slot = cellContentRect(forFlatIndex: index) else { return nil }
        guard cache.isResident(uid) else { return slot }
        let texture = cache.texture(for: uid)
        return TileContentFitter.fit(
            slotRect: slot,
            mediaPixelSize: CGSize(width: texture.width, height: texture.height),
            displayMode: effectiveDisplayMode
        ).contentRect
    }

    func cellContentRect(forFlatIndex index: Int) -> CGRect? {
        let width = layoutWidth
        guard width > 1 else { return nil }
        return engine.slotRect(flatIndex: index, level: level, width: width, columnPhase: currentPhase())
    }

    /// Whether the current level shows month/year labels (the dense overview levels).
    var showsMonthLabels: Bool { engine.metrics(level: level).monthLabels }

    var scrollOriginY: CGFloat { clipView?.bounds.origin.y ?? 0 }
    var viewportSize: CGSize { metalView?.bounds.size ?? clipView?.bounds.size ?? .zero }

    // MARK: - Leading obstruction inset
    //
    // The Metal surface remains full-width, while the engine lays out the grid in the unobscured region. The
    // inset drives layout width, final render translation, and event exclusion. Engine calculations use layout
    // space; the inset is applied once when draw slots are translated to render space.
    /// The sidebar obstruction width (points) - the floating sidebar's leading safe-area inset. Set by the host.
    var sidebarObstructionInset: CGFloat = 0 {
        didSet { if sidebarObstructionInset != oldValue { requestRedraw() } }
    }

    /// The window's translucent toolbar height. Mirrored onto the engine's `topInset` so the first grid row rests
    /// below the toolbar instead of under it (set by the host, plumbed from `MainView`). Re-applied on every
    /// engine rebuild (`rebuildIndex`) so a data change never silently drops it.
    var topBarInset: CGFloat = 0 {
        didSet {
            if topBarInset != oldValue {
                engine.topInset = topBarInset
                requestRedraw()
            }
        }
    }
    /// Additional leading space for normal levels while the sidebar is visible.
    var normalLevelLeadingGap: CGFloat = 0 {
        didSet {
            if normalLevelLeadingGap != oldValue {
                onContentSizeChange?(contentSize())
                requestRedraw()
            }
        }
    }
    /// Effective leading inset for a level, including the sidebar obstruction and normal-level margins.
    func effectiveLeadingInset(forLevel lvl: Int) -> CGFloat {
        let gap = (sidebarObstructionInset > 0 && !engine.metrics(level: lvl).monthLabels) ? normalLevelLeadingGap : 0
        return sidebarObstructionInset + gap + gridHorizontalMargin(forLevel: lvl)
    }
    /// Standard outer margin for normal levels. It stays constant across those levels so a transition does not
    /// change layout width while computing its anchor.
    private func gridHorizontalMargin(forLevel lvl: Int) -> CGFloat {
        engine.metrics(level: lvl).monthLabels ? 0 : Self.standardOuterMargin
    }
    /// The constant outer gutter (points) for the normal photo levels - see `gridHorizontalMargin` for why it must
    /// not vary by level.
    static let standardOuterMargin: CGFloat = 12
    /// Render/layout bounds for one level. The source of the insets stays adapter-owned; the mapping itself is a
    /// pure GridCore value so overview boundaries can resolve source and target independently.
    func renderBounds(forLevel lvl: Int) -> GridRenderBounds {
        GridRenderBounds(
            fullWidth: fullViewportWidth,
            leadingInset: effectiveLeadingInset(forLevel: lvl),
            trailingInset: gridHorizontalMargin(forLevel: lvl)
        )
    }
    /// Effective inset for the current level.
    var leadingObstructionInset: CGFloat { renderBounds(forLevel: level).leadingInset }
    /// The full on-screen viewport width in render space.
    private var fullViewportWidth: CGFloat { metalView?.bounds.width ?? clipView?.bounds.width ?? 0 }
    /// Width used by the engine for a level. Overview levels are edge-to-edge; normal levels use the outer margin.
    func layoutWidth(forLevel lvl: Int) -> CGFloat {
        renderBounds(forLevel: lvl).layoutWidth
    }
    /// Width used by engine, anchor, phase, and column calculations for the current level.
    var layoutWidth: CGFloat { layoutWidth(forLevel: level) }
    /// The viewport the engine lays out in: `layoutWidth` × full height.
    var layoutViewportSize: CGSize { renderBounds(forLevel: level).viewport(height: viewportSize.height) }

    /// Translates layout-space slots into render space and applies the leading inset once.
    private func renderTranslate(_ slots: [GridRenderSlot]) -> [GridRenderSlot] {
        renderBounds(forLevel: level).translate(slots)
    }

    /// Maps a dissolve target layer into its settled render bounds without scaling it again.
    private func mapDissolveTargetLayer(_ slots: [GridRenderSlot], targetBounds: GridRenderBounds) -> [GridRenderSlot] {
        targetBounds.translate(slots)
    }

    /// How many of `slots` currently have a resident (real, non-placeholder) texture. Used by the overview
    /// dissolve to detect when a layer's content changed (a wanted thumbnail streamed in) so only that layer is
    /// re-rasterized - a cheap `isResident` dict lookup per slot, far below re-running `buildRealGroups` + a
    /// full offscreen pass every frame.
    private func residentSlotCount(_ slots: [GridRenderSlot], flatUIDs: [PhotoUID]) -> Int {
        var count = 0
        for slot in slots where slot.index < flatUIDs.count {
            if cache.isResident(flatUIDs[slot.index]) { count += 1 }
        }
        return count
    }

    /// Visible cells (flat index + content rect) for the accessibility provider / header positioning.
    func visibleCells() -> [(flatIndex: Int, rect: CGRect)] {
        guard let clip = clipView, metalView != nil, layoutWidth > 1 else { return [] }
        let plan = engine.framePlan(
            level: level, viewportSize: layoutViewportSize, scrollOffset: clip.bounds.origin, overscan: 0,
            columnPhase: currentPhase())
        return plan.visibleSlots.map { ($0.index, $0.slotRect) }
    }

    /// The first visible cell + how far its top sits below the viewport top - captured before a level
    /// change so the same photo can be re-pinned afterward (anchor preservation).
    func anchorAtViewportTop() -> (uid: PhotoUID, offset: CGFloat)? {
        guard let clip = clipView, metalView != nil, layoutWidth > 1 else { return nil }
        let origin = clip.bounds.origin
        let plan = engine.framePlan(
            level: level, viewportSize: layoutViewportSize, scrollOffset: origin, overscan: 0,
            columnPhase: currentPhase())
        guard let top = plan.visibleSlots.min(by: { $0.slotRect.minY < $1.slotRect.minY }),
            let uid = uid(atFlatIndex: top.index)
        else { return nil }
        return (uid, top.slotRect.minY - origin.y)
    }

    func contentSize() -> CGSize {
        let width = layoutWidth
        guard width > 1 else { return .zero }
        // Height follows layout width. The document view remains full-width so pointer events cover the rendered
        // surface; the host excludes the obstructed region.
        let height = engine.contentSize(level: level, width: width, columnPhase: currentPhase()).height
        return CGSize(width: fullViewportWidth, height: height)
    }

    // MARK: - Live resize / sidebar presentation
    //
    // Window-width changes retain the current level's fixed columns and phase. Resolve only visible rows with
    // canonical gaps and the release camera, including rows exposed beyond the initial snapshot. Height-only
    // changes slide that snapshot. Thumbnail streaming remains live throughout either presentation.

    private(set) var presentationResizeActive = false
    /// Leading obstruction inset (sidebar overlap) + layout width captured at gesture start: the scale anchors the
    /// content's left edge at `inset` and scales by `currentLayoutWidth / startLayoutWidth`.
    private var presentationStartInset: CGFloat = 0
    private var presentationStartLayoutWidth: CGFloat = 1
    /// Settled slots captured at gesture start for height-only and sidebar presentation.
    private var presentationSnapshotSlots: [GridRenderSlot] = []
    private var presentationSnapshotDisplayMode: TileContentDisplayMode = .aspectFitInsideSquare
    /// Item pinned to the viewport bottom during a sidebar transition, or -1 when no item was captured.
    private var presentationBottomAnchorIndex = -1
    private var presentationBottomAnchorFracY: CGFloat = 1
    /// Item under the viewport center at resize start, or -1 when no item was captured.
    private var presentationCenterAnchorIndex = -1
    private var presentationCenterAnchorFracY: CGFloat = 0.5
    /// Whether the resize began at the newest end and should keep the last row bottom-pinned.
    private var presentationResizeBottomPinned = false
    /// The clip scroll captured at gesture start, which the vertical settle counter-scrolls from.
    private(set) var presentationStartScrollY: CGFloat = 0
    /// Vertical presentation offset applied by the host during a height resize. Zero for horizontal-only changes.
    var presentationVerticalShift: CGFloat = 0

    /// True only when the presentation can run (no zoom / transition / dissolve / commit / sidebar-anim in flight).
    var canPresentResize: Bool {
        zoomTransaction == nil && !gridTransition.isActive && overviewDissolve == nil && !isCommitBridging
            && !presentationSidebarActive
    }

    /// Captures the settled grid geometry used during live resize.
    private func captureSnapshot() {
        guard let clip = clipView, let view = metalView else { return }
        let viewportSize = view.bounds.size
        let w = layoutWidth
        let scrollY = clip.bounds.origin.y
        let phase = currentPhase()
        let overscan = max(budget.overscanFraction, 1.5) * viewportSize.height
        let lvp = CGSize(width: w, height: viewportSize.height)
        let plan = engine.framePlan(
            level: level, viewportSize: lvp, scrollOffset: CGPoint(x: 0, y: scrollY), overscan: overscan,
            columnPhase: phase)
        presentationSnapshotSlots = renderTranslate(
            plan.visibleSlots.map {
                GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect)
            })
        presentationSnapshotDisplayMode = effectiveDisplayMode
        presentationStartLayoutWidth = w
        presentationStartInset = leadingObstructionInset
        presentationStartScrollY = scrollY
    }

    /// Begin the live horizontal-resize presentation: snapshot the settled slots once and capture the item at the
    /// viewport bottom so it stays pinned there through the scale. Idempotent within a gesture.
    func beginPresentationResize() {
        guard !presentationResizeActive, let clip = clipView, let view = metalView else { return }
        if presentationSidebarActive { cancelSidebarResize() }  // a window resize supersedes a sidebar scale
        if resizeSettleActive { endResizeSettle() }  // a fresh drag during a settle supersedes it
        guard canPresentResize else { return }
        let viewportSize = view.bounds.size
        guard viewportSize.width > 1, viewportSize.height > 1 else { return }
        // Keep the last row bottom-pinned at the newest edge. Otherwise preserve the viewport center.
        presentationResizeBottomPinned = Self.resizeIsBottomPinned(
            scrollY: clip.bounds.origin.y,
            contentHeight: contentSize().height,
            viewportHeight: viewportSize.height)
        captureBottomAnchor()
        captureCenterAnchor()
        captureSnapshot()
        presentationVerticalShift = 0
        presentationResizeActive = true
    }

    /// Captures the bottom item and its local position for bottom-pinned resizing.
    private func captureBottomAnchor() {
        guard let clip = clipView, let view = metalView else {
            presentationBottomAnchorIndex = -1
            return
        }
        let w = layoutWidth
        let scrollY = clip.bounds.origin.y
        if let a = engine.anchorItem(
            nearContentPoint: CGPoint(x: w / 2, y: scrollY + view.bounds.height - 1),
            level: level, width: w, columnPhase: currentPhase())
        {
            presentationBottomAnchorIndex = a.flatIndex
            presentationBottomAnchorFracY = a.localFraction.y
        } else {
            presentationBottomAnchorIndex = -1
        }
    }

    /// Capture the item under the viewport centre (+ its in-cell Y fraction) so a window resize keeps it pinned at
    /// the centre through the scale and re-centres it on release (Apple-style: the thing you look at stays put).
    private func captureCenterAnchor() {
        guard let clip = clipView, let view = metalView else {
            presentationCenterAnchorIndex = -1
            return
        }
        let w = layoutWidth
        let scrollY = clip.bounds.origin.y
        let viewportHeight = view.bounds.height
        if let a = engine.anchorItem(
            nearContentPoint: CGPoint(x: w / 2, y: scrollY + viewportHeight / 2),
            level: level, width: w, columnPhase: currentPhase())
        {
            presentationCenterAnchorIndex = a.flatIndex
            presentationCenterAnchorFracY = a.localFraction.y
        } else {
            presentationCenterAnchorIndex = -1
        }
    }

    /// The bottom-anchored scroll for the captured anchor at the current layout width (clamped). Falls back to the
    /// gesture-start scroll when no anchor. Used by the sidebar settle so a toggle while scrolled to the newest end
    /// keeps the bottom row pinned (no jump) instead of reusing the frozen start scroll.
    private func bottomAnchoredScroll(width: CGFloat? = nil) -> CGFloat {
        guard presentationBottomAnchorIndex >= 0, let view = metalView else { return presentationStartScrollY }
        let viewportHeight = view.bounds.height
        let resolvedWidth = width ?? layoutWidth
        let y = engine.anchoredScrollOffsetY(
            flatIndex: presentationBottomAnchorIndex, relInCellY: presentationBottomAnchorFracY,
            contentFractionY: 1, viewportPointY: viewportHeight, level: level, width: resolvedWidth,
            columnPhase: currentPhase())
        return engine.clampScrollOffsetY(
            y, level: level, width: resolvedWidth, viewportHeight: viewportHeight, columnPhase: currentPhase())
    }

    /// Settled scroll that re-centers the captured center anchor at the current layout width.
    func centerAnchoredScroll(width: CGFloat? = nil) -> CGFloat {
        guard presentationCenterAnchorIndex >= 0, let view = metalView else { return presentationStartScrollY }
        let viewportHeight = view.bounds.height
        let resolvedWidth = width ?? layoutWidth
        let y = engine.anchoredScrollOffsetY(
            flatIndex: presentationCenterAnchorIndex, relInCellY: presentationCenterAnchorFracY,
            contentFractionY: 0.5, viewportPointY: viewportHeight / 2, level: level, width: resolvedWidth,
            columnPhase: currentPhase())
        return engine.clampScrollOffsetY(
            y, level: level, width: resolvedWidth, viewportHeight: viewportHeight, columnPhase: currentPhase())
    }

    /// Release scroll for a width or corner resize. Bottom-pinned resizes keep the last row at the bottom;
    /// other resizes re-center the captured item.
    func windowResizeReleaseScrollY() -> CGFloat {
        presentationResizeBottomPinned ? bottomAnchoredScroll() : centerAnchoredScroll()
    }

    /// End the presentation; the host syncs the clip to `centerAnchoredScroll()` and redraws the settled grid.
    func endPresentationResize() {
        presentationResizeActive = false
        presentationSnapshotSlots = []
        presentationVerticalShift = 0
    }

    // MARK: - Sidebar resize (full-surface presentation, canonical inset-driven destination)
    //
    // The floating sidebar is fixed-width, so open/close changes the grid's leading inset by a known amount. Resolve
    // the destination once, then interpolate each captured slot to that canonical rect while the sidebar slides.
    // This retains the zoom-like resize behind the translucent sidebar without scaling the fixed inter-cell gaps;
    // q=1 is therefore exactly the first settled frame and never needs a second "set" after the slide.
    private(set) var presentationSidebarActive = false
    var isSidebarResizing: Bool { presentationSidebarActive }
    /// from/to are layout insets (sidebar width + the normal-level gap) - what the scale fills to; `toEventInset`
    /// is the raw sidebar width committed to `sidebarObstructionInset` (the gap is re-added by the engine).
    private var presentationSidebarFromInset: CGFloat = 0
    private var presentationSidebarToInset: CGFloat = 0
    private var presentationSidebarToEventInset: CGFloat = 0
    private var presentationSidebarViewportWidth: CGFloat = 1
    private var presentationSidebarBottomPinned = false
    /// The canonical settled geometry at the destination inset, resolved once when the sidebar transition begins.
    /// Interpolating the captured source slots to these rects keeps the production fixed gaps intact and makes the
    /// final presentation frame byte-for-byte geometrically identical to the first settled frame.
    private(set) var presentationSidebarTargetSlots: [GridRenderSlot] = []
    private var presentationSidebarSlotPairs: [(source: GridRenderSlot, target: GridRenderSlot)] = []
    private var presentationSidebarTargetScroll: CGFloat = 0
    /// The raw sidebar width the transition starts from (`toEventInset` is its end).
    private var presentationSidebarFromEventInset: CGFloat = 0
    /// Shaped fraction (0...1) between the captured source and the canonical target that the presentation draws.
    /// With a measured sidebar edge it is the real fraction of the sidebar's travel, so the grid never leads or
    /// trails the sidebar; without one it follows the clock with `easeInOutCubic`. It never decreases.
    private(set) var presentationSidebarFraction: CGFloat = 0

    /// Duration of the clock-driven transition, used while no sidebar edge is measured.
    nonisolated static let sidebarClockDuration: CFTimeInterval = 0.22
    /// A transition that follows a measured edge ends at the latest after this time, even if the edge never arrives.
    nonisolated static let sidebarFollowDeadline: CFTimeInterval = 0.6
    /// The measured edge counts as arrived within this distance of the destination width (points).
    nonisolated static let sidebarArrivalTolerance: CGFloat = 0.5

    /// The layout inset (points) for a given sidebar obstruction width = the width plus, for a normal level with a
    /// sidebar, the breathing gap, plus the standard outer left margin - so the scale fills to exactly where the
    /// engine will lay the grid out (mirrors `effectiveLeadingInset`). Omitting the margin here left a margin-sized
    /// re-alignment at the end of the slide.
    private func sidebarLayoutInset(forWidth sidebarInset: CGFloat) -> CGFloat {
        let gap = (sidebarInset > 0 && !engine.metrics(level: level).monthLabels) ? normalLevelLeadingGap : 0
        return sidebarInset + gap + gridHorizontalMargin(forLevel: level)
    }

    /// Arm the sidebar transition: snapshot at the old inset (the engine inset must still be `fromInset` here),
    /// resolve the destination once, then pair source and target slots by identity. `fromInset`/`toInset` are the
    /// host's sidebar widths.
    /// Returns false when the caller must settle immediately.
    @discardableResult
    func beginSidebarResize(fromInset: CGFloat, toInset: CGFloat) -> Bool {
        if presentationSidebarActive { cancelSidebarResize() }  // a new toggle SUPERSEDES the in-flight scale
        guard canPresentResize, !presentationResizeActive, let view = metalView, let clip = clipView else {
            return false
        }
        let viewportSize = view.bounds.size
        guard viewportSize.width > 1, viewportSize.height > 1 else { return false }
        if resizeSettleActive { endResizeSettle() }
        presentationSidebarBottomPinned = Self.resizeIsBottomPinned(
            scrollY: clip.bounds.origin.y,
            contentHeight: contentSize().height,
            viewportHeight: viewportSize.height
        )
        captureBottomAnchor()
        captureCenterAnchor()
        captureSnapshot()
        presentationSidebarFromInset = sidebarLayoutInset(forWidth: fromInset)
        presentationSidebarToInset = sidebarLayoutInset(forWidth: toInset)
        presentationSidebarToEventInset = toInset
        // The right-anchor is the content's right edge = full width − the right margin (not the window edge), so the
        // scaled frame's right edge lands exactly where the settled grid's does (no end-of-slide re-alignment).
        presentationSidebarViewportWidth = viewportSize.width - gridHorizontalMargin(forLevel: level)
        let toLayoutW = max(1, presentationSidebarViewportWidth - presentationSidebarToInset)
        presentationSidebarTargetScroll =
            presentationSidebarBottomPinned
            ? bottomAnchoredScroll(width: toLayoutW)
            : centerAnchoredScroll(width: toLayoutW)
        let phase = currentPhase()
        let overscan = max(budget.overscanFraction, 1.5) * viewportSize.height
        let targetPlan = engine.framePlan(
            level: level,
            viewportSize: CGSize(width: toLayoutW, height: viewportSize.height),
            scrollOffset: CGPoint(x: 0, y: presentationSidebarTargetScroll),
            overscan: overscan,
            columnPhase: phase
        )
        presentationSidebarTargetSlots = targetPlan.visibleSlots.map {
            GridRenderSlot(
                index: $0.index, column: $0.column, row: $0.row,
                rect: $0.viewportRect.offsetBy(dx: presentationSidebarToInset, dy: 0))
        }
        let targetByIndex = Dictionary(
            uniqueKeysWithValues: presentationSidebarTargetSlots.map { ($0.index, $0) }
        )
        let sourceByIndex = Dictionary(uniqueKeysWithValues: presentationSnapshotSlots.map { ($0.index, $0) })
        let startLayoutW = max(1, presentationSidebarViewportWidth - presentationSidebarFromInset)
        let endScale = toLayoutW / startLayoutW
        let anchorY = presentationSidebarBottomPinned ? viewportSize.height : viewportSize.height / 2
        presentationSidebarSlotPairs = presentationSnapshotSlots.map { source in
            let target =
                targetByIndex[source.index]
                ?? GridRenderSlot(
                    index: source.index,
                    column: source.column,
                    row: source.row,
                    rect: Self.presentationScaledRectRightAnchored(
                        source.rect, scale: endScale,
                        rightX: presentationSidebarViewportWidth,
                        anchorY: anchorY
                    )
                )
            return (source, target)
        }
        presentationSidebarSlotPairs.append(
            contentsOf: presentationSidebarTargetSlots.compactMap { target in
                guard sourceByIndex[target.index] == nil else { return nil }
                let source = GridRenderSlot(
                    index: target.index,
                    column: target.column,
                    row: target.row,
                    rect: Self.presentationScaledRectRightAnchored(
                        target.rect, scale: 1 / max(endScale, 0.0001),
                        rightX: presentationSidebarViewportWidth,
                        anchorY: anchorY
                    )
                )
                return (source, target)
            })
        presentationSidebarFromEventInset = fromInset
        presentationSidebarFraction = 0
        presentationSidebarActive = true
        return true
    }

    /// Advances the sidebar transition by one display frame and returns true once it has arrived.
    ///
    /// `measuredEdge` is the real right edge of the sidebar in the same width terms as `fromInset`/`toInset` of
    /// `beginSidebarResize`, or nil when the host cannot read it. A measured edge sets the fraction directly, so the
    /// grid follows the sidebar's own curve and duration. Without one, the clock runs `sidebarClockDuration` with
    /// `easeInOutCubic`. `elapsed` is the time since the transition began.
    @discardableResult
    func advanceSidebarResize(elapsed: CFTimeInterval, measuredEdge: CGFloat?) -> Bool {
        let clock = CGFloat(min(1, max(0, elapsed / Self.sidebarClockDuration)))
        let travel = presentationSidebarToEventInset - presentationSidebarFromEventInset
        var fraction = Self.easeInOutCubic(clock)
        var arrived = clock >= 1
        if let edge = measuredEdge, abs(travel) > Self.sidebarArrivalTolerance {
            fraction = min(1, max(0, (edge - presentationSidebarFromEventInset) / travel))
            arrived = abs(edge - presentationSidebarToEventInset) <= Self.sidebarArrivalTolerance
        }
        if elapsed >= Self.sidebarFollowDeadline { arrived = true }
        presentationSidebarFraction = arrived ? 1 : max(presentationSidebarFraction, fraction)
        return arrived
    }

    /// Commit the sidebar transition at `toInset`. The last presented frame already equals the settled target; the
    /// defensive resize-settle path remains only for a future profile that changes column count.
    func endSidebarResize() -> (scroll: CGFloat, animating: Bool) {
        let startLayoutW = max(1, presentationSidebarViewportWidth - presentationSidebarFromInset)
        // Source is exactly the last frame the user saw. It has already reached the pre-resolved canonical target,
        // so committing the inset below cannot cause a second resize/vertical settle.
        let source = sidebarPresentationSlots(viewportSize: metalView?.bounds.size ?? .zero, progress: 1)
        presentationSidebarActive = false
        sidebarObstructionInset = presentationSidebarToEventInset  // commit the WIDTH (engine re-adds the gap)
        let scroll = presentationSidebarTargetScroll
        let target = presentationSidebarTargetSlots
        presentationSnapshotSlots = []
        presentationSidebarTargetSlots = []
        presentationSidebarSlotPairs = []
        let startCols = engine.resolvedMetrics(level: level, width: startLayoutW).columns
        let delta = Self.maxIndexedRectDelta(source: source, target: target)
        let targetCols = engine.resolvedMetrics(level: level, width: layoutWidth).columns
        guard targetCols != startCols, delta > 1.5 else {
            resizeSettleActive = false
            return (scroll, false)
        }
        resizeSettleSource = source
        resizeSettleTarget = target
        resizeSettleProgress = 0
        resizeSettleActive = true
        return (scroll, true)
    }

    /// Finalize an in-flight sidebar scale immediately - commit its target inset (engine re-adds the gap), drop the
    /// snapshot, and commit the inset. Used when a new toggle or a window resize supersedes it, so the engine inset
    /// can never end out of sync with the sidebar's actual state.
    func cancelSidebarResize() {
        guard presentationSidebarActive else { return }
        presentationSidebarActive = false
        sidebarObstructionInset = presentationSidebarToEventInset
        presentationSnapshotSlots = []
        presentationSidebarTargetSlots = []
        presentationSidebarSlotPairs = []
        presentationSidebarBottomPinned = false
    }

    /// Presents the sidebar resize snapshot at the current source-to-target interpolation.
    private func drawSidebarResize(to target: MetalGridDrawableTarget, viewportSize: CGSize, now: CFTimeInterval) {
        // Fixed gaps cannot be represented by one uniformly scaled quad, so keep this on bounded per-cell groups.
        let scaled = sidebarPresentationSlots(viewportSize: viewportSize, fraction: presentationSidebarFraction)
        let flatUIDs = dataSource.flatUIDs
        let (sourceVisible, sourceOverscan) = MetalGridFrameComposer.classifyVisibility(
            slots: scaled,
            flatUIDs: flatUIDs,
            viewportSize: viewportSize
        )
        let (targetVisible, targetOverscan) = MetalGridFrameComposer.classifyVisibility(
            slots: presentationSidebarTargetSlots,
            flatUIDs: flatUIDs,
            viewportSize: viewportSize
        )
        let admission = GridTextureStreamingPolicy.transitionWindow(
            sourceVisibleIDs: sourceVisible,
            targetVisibleIDs: targetVisible,
            overscanIDs: sourceOverscan + targetOverscan
        )
        let pendingVisibleQualityUpgrade = streamTextures(
            visibleUIDs: admission.visible,
            overscanUIDs: admission.overscan,
            allowUpgrade: true,
            now: now
        )
        let (groups, _) = buildRealGroups(
            slots: scaled,
            flatUIDs: flatUIDs,
            viewportSize: viewportSize,
            displayMode: presentationSnapshotDisplayMode
        )
        renderer.render(to: target, viewportSize: viewportSize, groups: groups)
        let activeReveal = hasActiveAnimation(in: admission.visible, now: now)
        hasPendingVisibleThumbnails =
            activeReveal
            || (!cache.residencySaturatedThisFrame
                && (pendingVisibleQualityUpgrade || hasRetryableMissingVisibleTexture(admission.visible)))
    }

    /// Presents the window-resize snapshot geometry while keeping thumbnail streaming live.
    private func drawPresentationResize(to target: MetalGridDrawableTarget, viewportSize: CGSize, now: CFTimeInterval) {
        let scaled = resizePresentationSlots(viewportSize: viewportSize)
        let flatUIDs = dataSource.flatUIDs
        let (visibleUIDs, overscanUIDs) = MetalGridFrameComposer.classifyVisibility(
            slots: scaled,
            flatUIDs: flatUIDs,
            viewportSize: viewportSize
        )
        let pendingVisibleQualityUpgrade = streamTextures(
            visibleUIDs: visibleUIDs,
            overscanUIDs: overscanUIDs,
            allowUpgrade: true,
            now: now
        )
        let realCount = renderRealSlots(
            to: target,
            slots: Self.viewportDrawSlots(scaled, viewportSize: viewportSize),
            flatUIDs: flatUIDs,
            viewportSize: viewportSize,
            now: now
        )
        let activeReveal = hasActiveAnimation(in: visibleUIDs, now: now)
        hasPendingVisibleThumbnails =
            activeReveal
            || (!cache.residencySaturatedThisFrame
                && (pendingVisibleQualityUpgrade || hasRetryableMissingVisibleTexture(visibleUIDs)))
        publishLightDiagnostics(
            phase: "liveResize",
            visibleCount: visibleUIDs.count,
            overscanCount: overscanUIDs.count,
            realCount: realCount,
            cellCount: scaled.count,
            visibleRect: CGRect(origin: CGPoint(x: 0, y: presentationStartScrollY), size: viewportSize),
            contentSize: contentSize(),
            now: now
        )
    }

    /// Keep item rows and columns while using the same fixed gaps and bounded camera as mouse-up.
    /// Height-only dragging retains its existing counter-scroll presentation.
    func resizePresentationSlots(viewportSize: CGSize) -> [GridRenderSlot] {
        let viewportHeight = viewportSize.height
        let inset = presentationStartInset
        // Subtract the right gutter too (the left gutter is already folded into `inset`): otherwise the snapshot
        // scales to fill width−inset and the standard outer margin vanishes during the drag (photos stick to the
        // right edge), then snaps back when the settled grid (which has the margin) renders on release.
        let curLayoutW = max(1, viewportSize.width - inset - gridHorizontalMargin(forLevel: level))
        if abs(curLayoutW - presentationStartLayoutWidth) > 0.5 {
            let scrollY = windowResizeReleaseScrollY()
            // A fixed-column plan preserves placement and covers rows newly exposed by a large shrink.
            // Query only the viewport plus bounded overscan; never resolve each captured item separately.
            let plan = engine.framePlan(
                level: level, viewportSize: CGSize(width: curLayoutW, height: viewportHeight),
                scrollOffset: CGPoint(x: 0, y: scrollY),
                overscan: max(budget.overscanFraction, 1.5) * viewportHeight, columnPhase: currentPhase())
            return plan.visibleSlots.map { slot in
                GridRenderSlot(
                    index: slot.index, column: slot.column, row: slot.row,
                    rect: slot.viewportRect.offsetBy(dx: inset, dy: 0))
            }
        }
        let k = curLayoutW / max(1, presentationStartLayoutWidth)
        let dy = presentationVerticalShift  // VERTICAL counter-scroll (pure-vertical only); tiles keep their size
        let anchorY = presentationResizeBottomPinned ? viewportHeight : viewportHeight / 2
        let scaled = presentationSnapshotSlots.map { s in
            GridRenderSlot(
                index: s.index, column: s.column, row: s.row,
                rect: Self.presentationScaledRect(s.rect, scale: k, insetX: inset, anchorY: anchorY).offsetBy(
                    dx: 0, dy: dy))
        }
        return scaled
    }

    /// Returns sidebar presentation geometry at normalized clock progress, shaped with `easeInOutCubic`.
    func sidebarPresentationSlots(viewportSize: CGSize, progress: CGFloat) -> [GridRenderSlot] {
        sidebarPresentationSlots(
            viewportSize: viewportSize, fraction: Self.easeInOutCubic(min(1, max(0, progress))))
    }

    /// Returns sidebar presentation geometry at a shaped fraction (0 = captured source, 1 = canonical target).
    func sidebarPresentationSlots(viewportSize _: CGSize, fraction: CGFloat) -> [GridRenderSlot] {
        let q = min(1, max(0, fraction))
        return presentationSidebarSlotPairs.map { pair in
            let s = pair.source.rect
            let t = pair.target.rect
            let r = CGRect(
                x: s.minX + (t.minX - s.minX) * q,
                y: s.minY + (t.minY - s.minY) * q,
                width: s.width + (t.width - s.width) * q,
                height: s.height + (t.height - s.height) * q
            )
            return GridRenderSlot(index: pair.target.index, column: pair.target.column, row: pair.target.row, rect: r)
        }
    }

    /// Scales a viewport rectangle about its left inset and horizontal anchor.
    ///
    /// The anchored content stays fixed and cells remain square. A scale of `1` is the identity.
    nonisolated static func presentationScaledRect(
        _ r: CGRect, scale k: CGFloat, insetX: CGFloat, anchorY: CGFloat
    ) -> CGRect {
        CGRect(
            x: insetX + (r.minX - insetX) * k,
            y: anchorY + (r.minY - anchorY) * k,
            width: r.width * k,
            height: r.height * k)
    }

    /// Scales a viewport rectangle about its right edge and horizontal anchor.
    ///
    /// Sidebar resizing keeps the right edge fixed while the left edge moves to the new inset.
    nonisolated static func presentationScaledRectRightAnchored(
        _ r: CGRect, scale k: CGFloat, rightX rightEdgeX: CGFloat, anchorY: CGFloat
    ) -> CGRect {
        CGRect(
            x: rightEdgeX - (rightEdgeX - r.minX) * k,
            y: anchorY + (r.minY - anchorY) * k,
            width: r.width * k,
            height: r.height * k)
    }

    /// The vertical counter-scroll slide (viewport pixels, y-down) for a height change of `dH` (= startH − curH,
    /// shrink positive). The dragging edge clips the majority; the opposite edge gives up fraction `f`. A bottom-
    /// edge drag slides up by f·dH (older rows leave the top); a top-edge drag slides up by (1−f)·dH (the bottom
    /// stays put). Zero anchors the dragged edge. One anchors the opposite edge.
    nonisolated static func verticalCounterScrollShift(dH: CGFloat, topEdgeDrag: Bool, fraction f: CGFloat) -> CGFloat {
        topEdgeDrag ? -(1 - f) * dH : -f * dH
    }

    /// Returns whether the scroll is close enough to the newest end to preserve bottom pinning.
    nonisolated static func resizeIsBottomPinned(
        scrollY: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat
    ) -> Bool {
        let maxScroll = max(0, contentHeight - viewportHeight)
        return scrollY >= maxScroll - 2
    }

    // MARK: - Resize settle (reserved for release-time column-count changes)
    //
    // A live resize scales the snapshot at the gesture-start column count. With fixed columns, release normally
    // resolves to the same column count and this morph is not armed. The path is retained defensively for any future
    // responsive policy that changes columns at release: every visible item's viewport rect eases from the last
    // scaled position to the settled position instead of snapping.
    private(set) var resizeSettleActive = false
    var isResizeSettling: Bool { resizeSettleActive }
    private var resizeSettleSource: [GridRenderSlot] = []
    private var resizeSettleTarget: [GridRenderSlot] = []
    /// Normalized resize-settle progress advanced by the display link.
    var resizeSettleProgress: CGFloat = 0

    /// Arms a release settle from the last scaled presentation frame to the settled layout. Returns false unless
    /// the release layout changed its column count.
    @discardableResult
    func beginResizeSettle(targetScrollY: CGFloat) -> Bool {
        guard presentationResizeActive, let view = metalView else {
            resizeSettleActive = false
            return false
        }
        let viewportSize = view.bounds.size
        let viewportHeight = viewportSize.height
        let inset = presentationStartInset
        let curLayoutW = max(1, viewportSize.width - inset - gridHorizontalMargin(forLevel: level))  // right gutter too
        // Start from the scaled and vertically shifted snapshot shown in the last live frame.
        let source = resizePresentationSlots(viewportSize: viewportSize)
        // The target uses the release width and the scroll the host will apply.
        let phase = currentPhase()
        let overscan = max(budget.overscanFraction, 1.5) * viewportHeight
        let lvp = CGSize(width: curLayoutW, height: viewportHeight)
        let plan = engine.framePlan(
            level: level, viewportSize: lvp, scrollOffset: CGPoint(x: 0, y: targetScrollY), overscan: overscan,
            columnPhase: phase)
        let target = renderTranslate(
            plan.visibleSlots.map {
                GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect)
            })
        // Fixed-column resizes normally need no morph. Arm only when a future policy produces a genuine reflow.
        let startCols = engine.resolvedMetrics(level: level, width: presentationStartLayoutWidth).columns
        let delta = Self.maxIndexedRectDelta(source: source, target: target)
        guard plan.columns != startCols, delta > 1.5 else {
            resizeSettleActive = false
            return false
        }
        resizeSettleSource = source
        resizeSettleTarget = target
        resizeSettleProgress = 0
        resizeSettleActive = true
        return true
    }

    func endResizeSettle() {
        resizeSettleActive = false
        resizeSettleSource = []
        resizeSettleTarget = []
    }

    /// Render the settle: each settled (target) slot eased from its scaled (source) position by `easeOut(progress)`.
    /// A target item with no source match (newly revealed at an edge) appears at its settled rect. Textures stream
    /// + decorations draw via the canonical real-slot path.
    private func drawResizeSettle(to target: MetalGridDrawableTarget, viewportSize: CGSize, now: CFTimeInterval) {
        let q = Self.easeOutCubic(min(1, max(0, resizeSettleProgress)))
        var srcByIndex: [Int: CGRect] = [:]
        srcByIndex.reserveCapacity(resizeSettleSource.count)
        for s in resizeSettleSource { srcByIndex[s.index] = s.rect }
        let slots: [GridRenderSlot] = resizeSettleTarget.map { t in
            guard let s = srcByIndex[t.index] else { return t }
            let r = CGRect(
                x: s.minX + (t.rect.minX - s.minX) * q,
                y: s.minY + (t.rect.minY - s.minY) * q,
                width: s.width + (t.rect.width - s.width) * q,
                height: s.height + (t.rect.height - s.height) * q)
            return GridRenderSlot(index: t.index, column: t.column, row: t.row, rect: r)
        }
        let pureViewport = CGRect(origin: .zero, size: viewportSize)
        let flatUIDs = dataSource.flatUIDs
        var visibleUIDs: [PhotoUID] = []
        var overscanUIDs: [PhotoUID] = []
        for s in slots where s.index < flatUIDs.count {
            if s.rect.intersects(pureViewport) {
                visibleUIDs.append(flatUIDs[s.index])
            } else {
                overscanUIDs.append(flatUIDs[s.index])
            }
        }
        streamTextures(visibleUIDs: visibleUIDs, overscanUIDs: overscanUIDs, now: now)
        _ = renderRealSlots(to: target, slots: slots, flatUIDs: flatUIDs, viewportSize: viewportSize)
        let activeReveal = hasActiveAnimation(in: visibleUIDs, now: now)
        hasPendingVisibleThumbnails =
            activeReveal
            || (!cache.residencySaturatedThisFrame && hasRetryableMissingVisibleTexture(visibleUIDs))
    }

    /// Max per-item rect delta (L1 of origin + size) between two index-keyed slot sets - 0 when every shared item
    /// sits in the same place, large when a future responsive policy reflows the same indexed items.
    nonisolated static func maxIndexedRectDelta(source: [GridRenderSlot], target: [GridRenderSlot]) -> CGFloat {
        var src: [Int: CGRect] = [:]
        src.reserveCapacity(source.count)
        for s in source { src[s.index] = s.rect }
        var maxD: CGFloat = 0
        for t in target {
            guard let r = src[t.index] else { continue }
            let d =
                abs(r.minX - t.rect.minX) + abs(r.minY - t.rect.minY) + abs(r.width - t.rect.width)
                + abs(r.height - t.rect.height)
            if d > maxD { maxD = d }
        }
        return maxD
    }

    /// easeOutCubic - fast start, gentle landing: the "fly into place" the resize settle wants.
    nonisolated static func easeOutCubic(_ q: CGFloat) -> CGFloat {
        let p = 1 - q
        return 1 - p * p * p
    }

    /// easeInOutCubic - slow ends, fast middle: matches a sidebar slide's acceleration.
    nonisolated static func easeInOutCubic(_ q: CGFloat) -> CGFloat {
        if q < 0.5 { return 4 * q * q * q }
        let u = -2 * q + 2
        return 1 - u * u * u / 2
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        onContentSizeChange?(contentSize())
    }

    func draw(in view: MTKView) {
        lastRenderOutcome = .skippedNoSurface
        guard let clip = clipView else { return }
        let viewportSize = view.bounds.size
        guard viewportSize.width > 1, viewportSize.height > 1 else { return }
        guard let target = MetalGridDrawableTarget(view: view) else {
            lastRenderOutcome = .noDrawable
            return
        }
        defer { lastRenderOutcome = .drawn(hasPendingWork: hasPendingVisibleThumbnails) }
        // Refresh the display backing scale from the live drawable (invariant to window size - the ratio is the
        // Retina factor). Set before any early-returning branch so every path that reaches `streamTextures`
        // sizes uploads against the current display.
        if view.bounds.width > 0, view.drawableSize.width > 0 {
            backingScale = max(1, view.drawableSize.width / view.bounds.width)
        }
        let now = CACurrentMediaTime()
        // During a live resize, present the gesture-start snapshot without re-resolving its grid.
        if presentationResizeActive {
            drawPresentationResize(to: target, viewportSize: viewportSize, now: now)
            return
        }
        // Sidebar open/close: interpolate captured slots to the once-resolved destination while leaving the full
        // Metal surface behind the glass. Separate from live window resize; driven by the host's timed tick.
        if presentationSidebarActive {
            drawSidebarResize(to: target, viewportSize: viewportSize, now: now)
            return
        }
        // A release settle is used only when the release layout changed its column count.
        if resizeSettleActive {
            drawResizeSettle(to: target, viewportSize: viewportSize, now: now)
            return
        }
        // Overview boundaries use an offscreen two-layer dissolve.
        if let plan = overviewDissolve {
            if overviewClickDissolveActive {
                let q = advanceClickOverviewDissolve(now: now)
                if q >= 1 {
                    finishClickOverviewDissolve()
                } else if let updated = overviewDissolve {
                    drawOverviewDissolve(to: target, plan: updated, viewportSize: viewportSize, now: now)
                    requestRedraw()
                    return
                }
            } else {
                drawOverviewDissolve(to: target, plan: plan, viewportSize: viewportSize, now: now)
                return
            }
        }
        // The host advances click progress from the display tick. Component progress remains a pure function of q.
        if gridTransition.isActive {
            // Live pinch progress comes from the host's scrub driver. Render the current progress and let the
            // host decide when to request the next frame.
            if gridTransition.activeKind == .pinch {
                drawTransition(to: target, viewportSize: viewportSize, now: now)
                return
            }
            // Click: q is the host-clock trapezoidal profile advanced per display tick.
            let dt = transitionPrevNow == 0 ? 1.0 / 60.0 : max(0, now - transitionPrevNow)
            transitionPrevNow = now
            if gridTransition.advanceClick(bySeconds: dt) {
                drawTransition(to: target, viewportSize: viewportSize, now: now)
                requestRedraw()  // keep ticking while the transition runs
                return
            }
            // Continue with settled rendering when the controller finishes this tick.
        }
        // Commit bridge (post-release geometry settle) takes precedence over the settled render.
        if isCommitBridging {
            drawCommitBridge(to: target, viewportSize: viewportSize, now: now)
            return
        }
        // Settled rendering draws the engine's frame plan.
        drawEngineFrame(to: target, clip: clip, viewportSize: viewportSize, now: now)
    }

    // MARK: - Single-lattice transition render

    /// Try to start a click transition
    /// for a toolbar/keyboard +/- to `newLevel`, pinning `anchorIndex` at `viewportPoint`. Commits the
    /// settled level/phase (so the post-settle frame is the target) and overlays the crossfade for the
    /// duration. Returns the target scroll position or `nil` when the caller must snap.
    func tryBeginClickTransition(
        toLevel newLevel: Int, anchorContentPoint: CGPoint,
        viewportPoint: CGPoint, viewportSize: CGSize
    ) -> CGFloat? {
        let lv = engine.clampLevel(newLevel)
        guard abs(lv - level) == 1 else { return nil }  // single-level steps only
        let lo = min(lv, level)
        guard engine.metrics(level: lo).transitionKindToNext == .focusRowRelayout else { return nil }
        let width = layoutWidth
        let lvp = layoutViewportSize
        guard
            let a = engine.anchorItem(
                nearContentPoint: anchorContentPoint, level: level, width: width,
                columnPhase: currentPhase())
        else { return nil }
        let overscan = budget.overscanFraction * viewportSize.height
        let srcScroll = clipView?.bounds.origin ?? .zero
        let src = engine.framePlan(
            level: level, viewportSize: lvp, scrollOffset: srcScroll,
            overscan: overscan, columnPhase: currentPhase())
        let desiredColumn = engine.cursorColumn(viewportX: viewportPoint.x, level: lv, width: width)
        let tgtPhase = engine.columnPhase(forItem: a.flatIndex, targetColumn: desiredColumn, level: lv, width: width)
        let tgtScroll = engine.anchoredScrollOffset(
            flatIndex: a.flatIndex, localFraction: a.localFraction,
            viewportPoint: viewportPoint, level: lv, width: width, columnPhase: tgtPhase)
        let tgt = engine.framePlan(
            level: lv, viewportSize: lvp, scrollOffset: CGPoint(x: 0, y: tgtScroll.y),
            overscan: overscan, columnPhase: tgtPhase)
        let began = PhotoPerformanceSignposts.grid.interval("transition.planBuild") {
            gridTransition.beginClick(
                source: src, target: tgt, anchorIndex: a.flatIndex,
                viewportSize: lvp, selection: selectedFlatIndices)
        }
        guard began else { return nil }
        committedPhase = tgtPhase  // commit settled target state (post-transition frame is the target)
        level = lv
        transitionPrevNow = 0
        requestRedraw()
        return tgtScroll.y
    }

    /// Discrete transition for overview boundaries: a fast dissolve between two complete
    /// grid layers. This intentionally does not use the per-photo relocation lattice.
    func tryBeginClickOverviewDissolve(
        toLevel newLevel: Int, anchorContentPoint: CGPoint,
        viewportPoint: CGPoint, viewportSize: CGSize
    ) -> CGFloat? {
        let sourceLevel = level
        let targetLevel = engine.clampLevel(newLevel)
        guard abs(sourceLevel - targetLevel) == 1,
            engine.isOverviewBoundary(sourceLevel, targetLevel)
        else { return nil }
        let sourceScrollY = clipView?.bounds.origin.y ?? 0
        let overscan = budget.overscanFraction * viewportSize.height
        let targetViewportSize = CGSize(width: layoutWidth(forLevel: targetLevel), height: layoutViewportSize.height)
        guard
            let plan = engine.overviewLayerDissolvePlan(
                from: sourceLevel, to: targetLevel,
                viewportSize: layoutViewportSize, targetViewportSize: targetViewportSize,
                sourceScrollY: sourceScrollY, sourceColumnPhase: currentPhase(),
                preferredNormalMode: preferredNormalLevelContentMode,
                anchorContentPoint: anchorContentPoint, anchorViewportPoint: viewportPoint, overscan: overscan)
        else { return nil }
        overviewDissolve = plan
        renderer.invalidateDissolveLayers()  // A new plan requires fresh layer textures.
        overviewClickDissolveActive = true
        overviewClickDissolveStart = 0
        committedPhase = plan.targetColumnPhase
        level = targetLevel
        requestRedraw()
        return plan.targetScrollY
    }

    private func advanceClickOverviewDissolve(now: CFTimeInterval) -> Double {
        if overviewClickDissolveStart == 0 { overviewClickDissolveStart = now }
        let elapsed = max(0, now - overviewClickDissolveStart)
        let q = overviewClickDissolveDuration > 0 ? min(1, elapsed / overviewClickDissolveDuration) : 1
        if let plan = overviewDissolve { overviewDissolve = plan.withProgress(q) }
        return q
    }

    private func finishClickOverviewDissolve() {
        overviewDissolve = nil
        renderer.endLayerDissolve()  // free the two offscreen dissolve textures; settled render doesn't use them
        overviewClickDissolveActive = false
        overviewClickDissolveStart = 0
        requestRedraw()
    }

    // MARK: - Live pinch single-lattice transition

    /// The lattice-eligible band around the coordinator's current level (shared `GridPinchRoutePolicy`;
    /// for the normal production levels this is `[0, 3]`, an overview start degenerates to `lo == hi`).
    func eligiblePinchChainBand() -> (lo: Int, hi: Int) {
        GridPinchRoutePolicy.chainBand(around: level, engine: engine)
    }

    /// The presentation frame parameters for one detent in the current gesture: the gesture-start detent keeps
    /// the actual on-screen (phase, scroll) - so q matches the live screen there and a return lands exactly -
    /// while every other detent is cursor-aligned (anchor pinned under the cursor). Because these are a pure
    /// function of the (fixed) anchor + the detent, any two adjacent segments sharing a detent get the identical
    /// frame for it, which keeps adjacent segment boundaries identical.
    private func pinchDetentParams(level lv: Int, viewportSize: CGSize) -> GridPinchDetentFrame {
        if lv == pinchStartLevel { return GridPinchDetentFrame(phase: pinchStartPhase, scrollY: pinchStartScrollY) }
        guard let tx = zoomTransaction else {
            return GridPinchDetentFrame(phase: currentPhase(), scrollY: pinchStartScrollY)
        }
        return GridPinchDetentGeometry.cursorAlignedFrame(
            level: lv, transaction: tx, engine: engine, width: layoutWidth, viewportHeight: viewportSize.height)
    }

    /// Builds the pinch plan for one adjacent source and target segment.
    /// Both detents resolve through `pinchDetentParams`, so a rebuild at a detent crossing is seam-continuous
    /// with the previous segment. Nothing is committed (level/phase/scroll stay at the gesture-start state; the
    /// actual scroll view stays frozen). Returns false when the host must use transaction reflow.
    func tryBuildPinchSegment(source: Int, target: Int, viewportSize: CGSize) -> Bool {
        guard zoomTransaction != nil else { return false }
        let s = engine.clampLevel(source)
        let t = engine.clampLevel(target)
        guard abs(s - t) == 1 else { return false }
        guard engine.metrics(level: min(s, t)).transitionKindToNext == .focusRowRelayout else { return false }
        let overscan = budget.overscanFraction * viewportSize.height
        let lvp = layoutViewportSize  // engine + transition plan are layout-space
        let sp = pinchDetentParams(level: s, viewportSize: lvp)
        let tp = pinchDetentParams(level: t, viewportSize: lvp)
        let srcPlan = engine.framePlan(
            level: s, viewportSize: lvp, scrollOffset: CGPoint(x: 0, y: sp.scrollY),
            overscan: overscan, columnPhase: sp.phase)
        let tgtPlan = engine.framePlan(
            level: t, viewportSize: lvp, scrollOffset: CGPoint(x: 0, y: tp.scrollY),
            overscan: overscan, columnPhase: tp.phase)
        guard let tx = zoomTransaction else { return false }
        let began = PhotoPerformanceSignposts.grid.interval("transition.planBuild") {
            gridTransition.beginPinch(
                source: srcPlan, target: tgtPlan, anchorIndex: tx.anchorGlobalIndex,
                viewportSize: lvp, selection: selectedFlatIndices)
        }
        guard began else { return false }
        pinchSegmentSource = s
        pinchSegmentTarget = t
        // Anticipatory prefetch: decode the full target-level visible set now, at segment build - the decode
        // pipeline then has the entire gesture as head-start, so the target tiles are RAM-resident by commit
        // instead of popping in black afterward (the banded fill). Independent of the per-frame warm pump, which
        // only streams the live crossfade subset of the committed viewport.
        let targetUIDs = tgtPlan.visibleSlots.compactMap { slot -> PhotoUID? in
            let i = slot.index
            return (i >= 0 && i < dataSource.flatUIDs.count) ? dataSource.flatUIDs[i] : nil
        }
        dataSource.prefetchWarm(targetUIDs)
        requestRedraw()
        return true
    }

    /// Drive the active segment's progress (the scrub driver's `segmentQ`). q is authoritative; the plan's
    /// per-component crossfade is a pure function of it (reversible).
    func setPinchProgress(_ q: Double) {
        guard gridTransition.activeKind == .pinch else { return }
        gridTransition.setProgress(q)
        requestRedraw()
    }

    /// Commit the chain to the settled detent `finalLevel` (the level the gesture landed on): adopt that
    /// detent's (phase, scroll), end the plan, clear the transaction. Returns the scroll-Y the host scrolls to
    /// - the settled frame then matches the plan's `finalLevel` endpoint exactly (no seam). For the gesture
    /// start detent this is the actual scroll (a no-op return-to-start). `logPostCommitAnchor` after scrolling.
    @discardableResult
    func commitPinchChain(toLevel finalLevel: Int, viewportSize: CGSize) -> CGFloat {
        let lv = engine.clampLevel(finalLevel)
        let p = pinchDetentParams(level: lv, viewportSize: viewportSize)
        if lv != pinchStartLevel {
            committedPhase = p.phase
            level = lv
        }
        gridTransition.end()
        zoomTransaction = nil
        endPinchTransition()
        requestRedraw()
        return p.scrollY
    }

    /// Ends the active pinch plan without committing a level change.
    /// The host can reuse the live transaction for its reflow fallback.
    func abortPinchPlan() {
        gridTransition.end()
        endPinchTransition()
        requestRedraw()
    }

    private func endPinchTransition() {
        pinchSegmentSource = nil
        pinchSegmentTarget = nil
        transitionPrevNow = 0
    }

    // MARK: - Overview layer dissolve

    /// Builds a cursor-anchored dissolve between adjacent overview levels.
    /// Returns `false` without committing state when the caller must use the reflow fallback.
    func beginOverviewDissolve(sourceLevel s: Int, targetLevel t: Int, viewportSize: CGSize) -> Bool {
        guard let tx = zoomTransaction,
            engine.isOverviewBoundary(s, t)
        else { return false }
        let srcScrollY = clipView?.bounds.origin.y ?? 0
        let overscan = budget.overscanFraction * viewportSize.height
        let cursorContent = CGPoint(x: tx.anchorViewportPoint.x, y: tx.anchorViewportPoint.y + srcScrollY)
        let targetViewportSize = CGSize(width: layoutWidth(forLevel: t), height: layoutViewportSize.height)
        guard
            let plan = engine.overviewLayerDissolvePlan(
                from: s, to: t, viewportSize: layoutViewportSize, targetViewportSize: targetViewportSize,
                sourceScrollY: srcScrollY, sourceColumnPhase: currentPhase(),
                preferredNormalMode: preferredNormalLevelContentMode,
                anchorContentPoint: cursorContent, anchorViewportPoint: tx.anchorViewportPoint, overscan: overscan)
        else { return false }
        overviewDissolve = plan
        renderer.invalidateDissolveLayers()  // A new plan requires fresh layer textures.
        requestRedraw()
        return true
    }

    /// Update the dissolve progress (0 = source, 1 = target). Rebuilds nothing - only the blend moves.
    func setOverviewDissolveProgress(_ q: Double) {
        guard let d = overviewDissolve else { return }
        overviewDissolve = d.withProgress(q)
        requestRedraw()
    }

    /// Commit the dissolve to source (no change) or target (adopt the target level/phase + anchored scroll).
    /// Returns the scroll-Y to settle at; the settled render then matches the chosen endpoint exactly.
    @discardableResult
    func commitOverviewDissolve(toTarget: Bool, viewportSize: CGSize) -> CGFloat {
        let srcScrollY = clipView?.bounds.origin.y ?? 0
        guard let d = overviewDissolve else { return srcScrollY }
        let scrollY: CGFloat
        if toTarget {
            committedPhase = d.targetColumnPhase
            level = d.targetLevel
            scrollY = d.targetScrollY
        } else {
            scrollY = srcScrollY
        }
        overviewDissolve = nil
        renderer.endLayerDissolve()  // free the two offscreen dissolve textures; settled render doesn't use them
        overviewClickDissolveActive = false
        overviewClickDissolveStart = 0
        zoomTransaction = nil
        requestRedraw()
        return scrollY
    }

    /// Render the active dissolve: build each layer's settled groups (source keeps its mode; target square),
    /// stream both layers' textures, and hand them to the offscreen compositor as `mix(source, target, ease(q))`.
    private func drawOverviewDissolve(
        to target: MetalGridDrawableTarget, plan: OverviewLayerDissolvePlan, viewportSize: CGSize, now: CFTimeInterval
    ) {
        let flatUIDs = dataSource.flatUIDs
        let srcSlots = renderTranslate(
            plan.source.visibleSlots.map {
                GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect)
            })
        // Use the target layer's settled bounds to keep the overview boundary continuous.
        let tgtSlots = mapDissolveTargetLayer(
            plan.target.visibleSlots.map {
                GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect)
            },
            targetBounds: renderBounds(forLevel: plan.targetLevel)
        )
        var uids: [PhotoUID] = []
        for s in srcSlots where s.index < flatUIDs.count { uids.append(flatUIDs[s.index]) }
        for s in tgtSlots where s.index < flatUIDs.count { uids.append(flatUIDs[s.index]) }
        // Rebuild a frozen layer only when one of its required thumbnails becomes resident.
        let srcResidentBefore = residentSlotCount(srcSlots, flatUIDs: flatUIDs)
        let tgtResidentBefore = residentSlotCount(tgtSlots, flatUIDs: flatUIDs)
        streamTextures(visibleUIDs: uids, overscanUIDs: [], now: now)
        let srcResidentAfter = residentSlotCount(srcSlots, flatUIDs: flatUIDs)
        let tgtResidentAfter = residentSlotCount(tgtSlots, flatUIDs: flatUIDs)
        let activeReveal = hasActiveAnimation(in: uids, now: now)
        evictTexturesToBudget()
        PhotoPerformanceSignposts.grid.interval("dissolve.layerPass") {
            renderer.renderLayerDissolve(
                to: target, viewportSize: viewportSize,
                redrawSource: srcResidentAfter != srcResidentBefore || activeReveal,
                redrawTarget: tgtResidentAfter != tgtResidentBefore || activeReveal,
                sourceGroups: {
                    PhotoPerformanceSignposts.grid.interval("buildRealGroups") {
                        buildRealGroups(
                            slots: srcSlots, flatUIDs: flatUIDs, viewportSize: viewportSize,
                            displayMode: plan.sourceDisplayMode, now: now
                        ).0
                    }
                },
                targetGroups: {
                    PhotoPerformanceSignposts.grid.interval("buildRealGroups") {
                        buildRealGroups(
                            slots: tgtSlots, flatUIDs: flatUIDs, viewportSize: viewportSize,
                            displayMode: plan.targetDisplayMode, now: now
                        ).0
                    }
                },
                t: Float(plan.targetOpacity))
        }
        hasPendingVisibleThumbnails =
            activeReveal
            || (!cache.residencySaturatedThisFrame && hasRetryableMissingVisibleTexture(uids))
        publishLightDiagnostics(
            phase: "overviewDissolve", visibleCount: uids.count, overscanCount: 0,
            realCount: srcResidentAfter + tgtResidentAfter,
            cellCount: srcSlots.count + tgtSlots.count,
            visibleRect: CGRect(origin: .zero, size: viewportSize),
            contentSize: engine.contentSize(
                level: plan.targetLevel, width: layoutWidth,
                columnPhase: plan.targetColumnPhase), now: now)
    }

    private func drawTransition(to target: MetalGridDrawableTarget, viewportSize: CGSize, now: CFTimeInterval) {
        let draws = gridTransition.currentDraws()
        let flatUIDs = dataSource.flatUIDs
        // stream textures for the union of source+target occupants currently drawn
        var uids: [PhotoUID] = []
        for d in draws where d.index < flatUIDs.count { uids.append(flatUIDs[d.index]) }
        streamTextures(visibleUIDs: uids, overscanUIDs: [], now: now)
        let realCount = renderTransitionDraws(
            to: target, draws: draws, flatUIDs: flatUIDs, viewportSize: viewportSize, now: now)
        publishLightDiagnostics(
            phase: "transition", visibleCount: uids.count, overscanCount: 0,
            realCount: realCount, cellCount: draws.count,
            visibleRect: CGRect(origin: .zero, size: viewportSize),
            contentSize: engine.contentSize(level: level, width: layoutWidth, columnPhase: currentPhase()),
            now: now)
    }

    /// Renders transition draws with the premultiplied source-over blend. Mixed draws use an opaque source
    /// followed by the target at local progress. All draws use the renderer's uniform clear surface.
    @discardableResult
    private func renderTransitionDraws(
        to target: MetalGridDrawableTarget, draws: [GridTransitionDraw], flatUIDs: [PhotoUID],
        viewportSize: CGSize, now: TimeInterval
    ) -> Int {
        let output = MetalGridFrameComposer.buildTransitionGroups(
            draws: draws,
            flatUIDs: flatUIDs,
            cache: cache,
            displayMode: effectiveDisplayMode,
            cornerRadius: GridVisualConstants.thumbnailCornerRadius,
            decorations: productionDecorations(),
            rectTransform: { [leadingObstructionInset] in
                $0.offsetBy(dx: leadingObstructionInset, dy: 0)
            },
            now: now
        )
        evictTexturesToBudget()
        renderer.render(to: target, viewportSize: viewportSize, groups: output.groups)
        return output.realCount
    }

    /// The geometry-only commit bridge: smooth only the sub-cell residual between the transaction-final frame
    /// and the cursor-aligned phased settled plan (the multi-column phase mismatch is removed structurally by
    /// `committedPhase`, so nothing flies across columns). At p=0 this equals the live transaction's final
    /// frame; at p=1 it equals the settled (phased) `GridFramePlan`. No crossfade, no photo replacement.
    private func drawCommitBridge(to target: MetalGridDrawableTarget, viewportSize: CGSize, now: CFTimeInterval) {
        guard let tx = bridgeTransaction else { return }
        let overscan = budget.overscanFraction * viewportSize.height
        let scrollOffset = CGPoint(x: 0, y: bridgeScrollY)
        // One source of truth for the bridge geometry (also what the tests assert against): per-globalIndex
        // viewport rects eased from the transaction-final frame to the settled (phased) `GridFramePlan`.
        // Built in layout space (engine), then translated +inset to render space (the bridge draw chokepoint).
        let slots = renderTranslate(
            GridZoomCommitBridge.frame(
                transaction: tx, engine: engine, targetLevel: bridgeLevel,
                viewportSize: layoutViewportSize, scrollY: bridgeScrollY,
                overscan: overscan, progress: commitBridgeProgress, columnPhase: currentPhase()))
        let settledContentSize = engine.contentSize(level: bridgeLevel, width: layoutWidth, columnPhase: currentPhase())
        let flatUIDs = dataSource.flatUIDs
        let (visibleUIDs, overscanUIDs) = MetalGridFrameComposer.classifyVisibility(
            slots: slots, flatUIDs: flatUIDs, viewportSize: viewportSize)
        streamTextures(visibleUIDs: visibleUIDs, overscanUIDs: overscanUIDs, now: now)
        let realCount = renderRealSlots(
            to: target, slots: Self.viewportDrawSlots(slots, viewportSize: viewportSize),
            flatUIDs: flatUIDs, viewportSize: viewportSize, now: now)
        let activeReveal = hasActiveAnimation(in: visibleUIDs, now: now)
        hasPendingVisibleThumbnails =
            activeReveal
            || (!cache.residencySaturatedThisFrame && hasRetryableMissingVisibleTexture(visibleUIDs))
        publishLightDiagnostics(
            phase: "commitBridge", visibleCount: visibleUIDs.count,
            overscanCount: overscanUIDs.count, realCount: realCount, cellCount: slots.count,
            visibleRect: CGRect(origin: scrollOffset, size: viewportSize),
            contentSize: settledContentSize, now: now)
    }

    // MARK: - Engine render

    /// Resolves a `GridFramePlan` and draws its square slots. The engine owns settled and live geometry.
    private func drawEngineFrame(
        to target: MetalGridDrawableTarget, clip: NSClipView, viewportSize: CGSize, now: CFTimeInterval
    ) {
        let overscan = budget.overscanFraction * viewportSize.height
        // Render in viewport space. Both paths produce `GridRenderSlot` (viewport-space); the engine's
        // content-space `GridSlot.slotRect` is mapped to a viewport rect here, never reused with a live rect.
        let slots: [GridRenderSlot]
        let contentSizeForDiag: CGSize
        if let tx = zoomTransaction {
            // Live zoom uses the engine-owned transaction so the focus row stays stable while the level changes.
            let frame = tx.frame(
                continuousLevel: zoomTransactionLevel, viewportSize: layoutViewportSize, overscan: overscan)
            slots = renderTranslate(frame.visibleSlots)  // Translate layout once at the render boundary.
            contentSizeForDiag = CGSize(
                width: layoutWidth, height: frame.pitch * CGFloat(max(1, slots.count / max(frame.columns, 1))))
            #if DEBUG
                if now - lastCommitFrameLog > 0.1 {  // ~10 Hz: trace the live focus row + anchor rect (DEBUG only;
                    lastCommitFrameLog = now  // the diagnostic builds a payload string, so keep it out of release)
                    let anchorRect = frame.visibleSlots.first { $0.index == tx.anchorGlobalIndex }?.rect ?? .zero
                    GridZoomCommitLog.frame(
                        progress: zoomTransactionLevel, anchorViewportRect: anchorRect,
                        focusRow: frame.focusRow, focusRowStable: frame.focusRow.contains(tx.anchorGlobalIndex))
                }
            #endif
        } else {
            // Settled rendering follows the native scroll origin, including AppKit's temporary elastic range.
            // Zoom and overview commits arm `rebaseActive` when a content-size change needs camera correction.
            let phase = currentPhase()
            let rawOrigin = clip.bounds.origin
            // The Y the grid actually renders at: normally the native clip origin (including elastic
            // overscroll), or an explicitly-armed rebase interpolation after a zoom/overview commit.
            let renderY: CGFloat
            if rebaseActive {
                let p = GridScrollRebase.progress(start: rebaseStart, now: now)
                renderY = GridScrollRebase.scrollY(fromY: rebaseFromY, toY: rebaseToY, progress: p)
                if p >= 1 { rebaseActive = false }  // settled exactly at toY this frame
            } else {
                renderY = rawOrigin.y
            }
            let plan = PhotoPerformanceSignposts.grid.interval("framePlan") {
                engine.framePlan(
                    level: level, viewportSize: layoutViewportSize,
                    scrollOffset: CGPoint(x: rawOrigin.x, y: renderY), overscan: overscan, columnPhase: phase)
            }
            slots = renderTranslate(
                plan.visibleSlots.map {
                    GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect)
                })
            contentSizeForDiag = plan.contentSize
        }

        let flatUIDs = dataSource.flatUIDs
        let (visibleUIDs, overscanUIDs) = MetalGridFrameComposer.classifyVisibility(
            slots: slots, flatUIDs: flatUIDs, viewportSize: viewportSize)
        // Settled frames can upgrade carried-over textures.
        let pendingVisibleQualityUpgrade = streamTextures(
            visibleUIDs: visibleUIDs, overscanUIDs: overscanUIDs,
            allowUpgrade: zoomTransaction == nil, now: now)
        let realCount = renderRealSlots(
            to: target, slots: Self.viewportDrawSlots(slots, viewportSize: viewportSize),
            flatUIDs: flatUIDs, viewportSize: viewportSize, now: now)
        // Keep ticking while visible placeholders or quality upgrades can still complete.
        // Residency saturation waits for a later viewport change.
        let activeReveal = hasActiveAnimation(in: visibleUIDs, now: now)
        hasPendingVisibleThumbnails =
            activeReveal
            || (!cache.residencySaturatedThisFrame
                && (pendingVisibleQualityUpgrade || hasRetryableMissingVisibleTexture(visibleUIDs)))
        publishLightDiagnostics(
            phase: zoomTransaction == nil ? "settled" : "liveZoom",
            visibleCount: visibleUIDs.count, overscanCount: overscanUIDs.count,
            realCount: realCount, cellCount: slots.count,
            visibleRect: CGRect(origin: clip.bounds.origin, size: viewportSize),
            contentSize: contentSizeForDiag, now: now)
    }

    /// Resident images are cover-filled inside square slots. Missing thumbnails leave the uniform clear surface.
    nonisolated static func viewportDrawSlots(_ slots: [GridRenderSlot], viewportSize: CGSize) -> [GridRenderSlot] {
        MetalGridFrameComposer.viewportDrawSlots(slots, viewportSize: viewportSize)
    }

    @discardableResult
    private func renderRealSlots(
        to target: MetalGridDrawableTarget,
        slots: [GridRenderSlot],
        flatUIDs: [PhotoUID],
        viewportSize: CGSize,
        now: TimeInterval = CACurrentMediaTime()
    ) -> Int {
        let transition = activeContentModeTransition()
        let (groups, realCount) = PhotoPerformanceSignposts.grid.interval("buildRealGroups") {
            buildRealGroups(
                slots: slots, flatUIDs: flatUIDs, viewportSize: viewportSize,
                displayMode: effectiveDisplayMode, contentTransition: transition, now: now)
        }
        evictTexturesToBudget()
        renderer.render(to: target, viewportSize: viewportSize, groups: groups)
        if transition != nil { requestRedraw() }
        return realCount
    }

    private func activeContentModeTransition() -> TileContentDisplayTransition? {
        guard let transition = contentModeTransition else { return nil }
        let elapsed = CACurrentMediaTime() - transition.startedAt
        let progress = min(1, max(0, elapsed / contentModeTransitionDuration))
        if progress >= 1 {
            contentModeTransition = nil
            return nil
        }
        return TileContentDisplayTransition(
            from: transition.from,
            to: transition.to,
            progress: CGFloat(progress)
        )
    }

    /// Builds settled-grid render groups for an explicit display mode. The caller owns eviction and drawing.
    private func buildRealGroups(
        slots: [GridRenderSlot], flatUIDs: [PhotoUID], viewportSize: CGSize,
        displayMode: TileContentDisplayMode,
        contentTransition: TileContentDisplayTransition? = nil,
        now: TimeInterval = CACurrentMediaTime()
    ) -> (groups: [MetalGridRenderGroup], realCount: Int) {
        // The shared composer supplies geometry, textures, and platform-neutral decorations.
        return MetalGridFrameComposer.buildGroups(
            slots: slots, flatUIDs: flatUIDs, cache: cache,
            displayMode: displayMode, cornerRadius: GridVisualConstants.thumbnailCornerRadius,
            decorations: productionDecorations(), contentTransition: contentTransition, now: now
        )
    }

    /// A thumbnail fading in or an upload badge moving keeps the grid drawing frames.
    private func hasActiveAnimation(in uids: [PhotoUID], now: CFTimeInterval) -> Bool {
        cache.hasActiveThumbnailReveal(in: uids, now: now) || uploadBadgeAnimator.isAnimating(uids, now: now)
    }

    private func productionDecorations() -> MetalGridDecorations<PhotoUID>? {
        guard decorationsEnabled else { return nil }
        // One time for the whole frame, so every badge of the frame animates in step.
        let frameTime = CACurrentMediaTime()
        return MetalGridDecorations(
            accent: Self.colorVector(.controlAccentColor),
            accentGlyphColor: MetalGridGlyphColor(.controlAccentColor),
            selectionMode: selectionMode,
            selected: selectedUIDs,
            favorites: favoriteUIDs,
            overlay: { [dataSource] uid in dataSource.thumbnailOverlay(for: uid) },
            uploadBadgeFrame: { [uploadBadgeAnimator] uid, badge in
                uploadBadgeAnimator.frame(for: uid, target: badge, now: frameTime)
            }
        )
    }

    private static func colorVector(_ color: NSColor) -> SIMD4<Float> {
        let c = color.usingColorSpace(.sRGB) ?? color
        return SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), Float(c.alphaComponent))
    }
}

// MARK: - Canonical render helpers (shared by the engine draw path)

extension MetalGridCoordinator {
    /// Returns the shared slot-size-derived corner radius.
    private func cellRadius(_ base: Float, cell: CGRect) -> Float {
        MetalGridFrameComposer.cellRadius(base: CGFloat(base), cell: cell)
    }

    // MARK: Texture streaming (visible-first upload + off-main warm)

    private func hasRetryableMissingVisibleTexture(_ uids: [PhotoUID]) -> Bool {
        uids.contains { !cache.isResident($0) && dataSource.canRetryThumbnail(for: $0) }
    }

    @discardableResult
    private func streamTextures(
        visibleUIDs: [PhotoUID],
        overscanUIDs: [PhotoUID],
        allowUpgrade: Bool = false,
        now: TimeInterval = CACurrentMediaTime()
    ) -> Bool {
        // Streaming policy is shared with the iOS host. This adapter supplies upload sizing, warm requests, and
        // cache state.
        let uploadPixels = effectiveUploadPixels()
        let result = MetalGridFrameComposer.stream(
            cache: cache,
            visibleIDs: visibleUIDs,
            overscanIDs: overscanUIDs,
            effectiveUploadPixels: uploadPixels,
            allowUpgrade: allowUpgrade,
            now: now,
            hasImage: { [dataSource] uid in dataSource.hasImage(for: uid) },
            canRetry: { [dataSource] uid in dataSource.canRetryThumbnail(for: uid) },
            provideImage: { [dataSource] uid in dataSource.image(for: uid) },
            signposts: composeSignposts
        )
        let pendingVisibleQualityUpgrade = result.pendingVisibleQualityUpgrade
        PhotoDiagnostics.shared.emitDebug(
            "ThumbViewport",
            fields: {
                let visibleResident = visibleUIDs.reduce(into: 0) { count, uid in
                    if cache.isResident(uid) { count += 1 }
                }
                let retryableMissing = visibleUIDs.reduce(into: 0) { count, uid in
                    if !cache.isResident(uid), dataSource.canRetryThumbnail(for: uid) { count += 1 }
                }
                return [
                    "level": "\(level)",
                    "visible": "\(visibleUIDs.count)",
                    "resident": "\(visibleResident)",
                    "missing": "\(visibleUIDs.count - visibleResident)",
                    "retryableMissing": "\(retryableMissing)",
                    "overscan": "\(overscanUIDs.count)",
                    "warm": "\(result.warm.count)",
                    "uploads": "\(cache.uploadsThisFrame)",
                    "deferredUploads": "\(cache.deferredUploadsThisFrame)",
                    "pendingUpgrade": "\(pendingVisibleQualityUpgrade)",
                ]
            }, throttleSeconds: 0.25, throttleKey: "frame")
        if !result.warm.isEmpty {
            let requests = result.warm.map {
                ThumbnailRequest(uid: $0, pixelSize: uploadPixels, cropMode: effectiveDisplayMode.rawValue)
            }
            dataSource.warm(requests)
            hasVisibleDemand = true
        } else if hasVisibleDemand {
            hasVisibleDemand = false
            dataSource.endVisibleDemand()
        }
        // Duration lives in encrypted metadata, not the timeline enumeration. Ask only for already-resident
        // visible videos; the shared resolver debounces until the viewport is stable, so this never competes
        // with thumbnail fill during fast scrolling.
        dataSource.resolveOverlays(for: visibleUIDs.filter { cache.isResident($0) })
        // Record the first visible frame and the first resident thumbnail for diagnostics.
        if !firstContentTraced, !visibleUIDs.isEmpty {
            firstContentTraced = true
            firstGridFrameAt = CACurrentMediaTime()
            let missing = visibleUIDs.reduce(into: 0) { $0 += cache.isResident($1) ? 0 : 1 }
            PhotoDiagnostics.shared.emit(
                "FirstContent",
                [
                    "event": "gridFrame", "visible": "\(visibleUIDs.count)", "missing": "\(missing)",
                    "resident": "\(visibleUIDs.count - missing)", "level": "\(level)", "phase": "coldStart",
                ])
        }
        // Notify the shell after the first visible thumbnail for this data source. Remaining thumbnails continue
        // loading behind the presented grid. A later revision resets `contentReadyReported` for the next cycle.
        if !contentReadyReported, !visibleUIDs.isEmpty,
            visibleUIDs.contains(where: { cache.isResident($0) })
        {
            contentReadyReported = true
            if !firstContentReadyLogged {
                firstContentReadyLogged = true
                let elapsedMs = firstGridFrameAt > 0 ? (CACurrentMediaTime() - firstGridFrameAt) * 1000 : 0
                let resident = visibleUIDs.reduce(into: 0) { $0 += cache.isResident($1) ? 1 : 0 }
                PhotoDiagnostics.shared.emit(
                    "FirstContent",
                    [
                        "event": "ready", "visible": "\(visibleUIDs.count)", "resident": "\(resident)",
                        "elapsedMs": String(format: "%.0f", elapsedMs), "level": "\(level)", "phase": "coldStart",
                    ])
            }
            onContentReady?()
        }
        return pendingVisibleQualityUpgrade
    }

    private func evictTexturesToBudget() {
        PhotoPerformanceSignposts.grid.interval("evictToBudget") {
            cache.evictToBudget()
        }
    }

    private func publishLightDiagnostics(
        phase: String, visibleCount: Int, overscanCount: Int, realCount: Int,
        cellCount: Int, visibleRect: CGRect, contentSize: CGSize, now: CFTimeInterval
    ) {
        guard now - lastHUDPushDetent > 0.1 else { return }
        lastHUDPushDetent = now
        let stats = MetalGridStats.frame(
            visibleCount: visibleCount,
            overscanCount: overscanCount,
            realCount: realCount,
            cellCount: cellCount,
            textureUploads: cache.uploadsThisFrame,
            textureUploadBytes: cache.uploadBytesThisFrame,
            deferredTextureUploads: cache.deferredUploadsThisFrame,
            textureUploadMs: cache.uploadMsThisFrame,
            evictions: cache.evictionsThisFrame,
            evictMs: cache.evictMsThisFrame,
            residentBytes: cache.residentBytes,
            residentTextureCount: cache.residentCount,
            pinnedTextureCount: cache.pinnedCount,
            textureCapacity: cache.residencyCapacity,
            pinnedTextureOverflow: cache.pinnedOverflow,
            residentByteBudget: cache.residentByteBudget,
            uploadByteBudget: cache.uploadByteBudgetPerFrame,
            byteBudgetOverflow: cache.byteBudgetOverflow,
            residencySaturated: cache.residencySaturatedThisFrame,
            drawCalls: renderer.lastDrawCalls,
            textureBinds: renderer.lastTextureBinds,
            instanceCount: renderer.lastInstanceCount,
            drawMs: renderer.lastEncodeMs,
            gpuMs: renderer.lastGpuMs
        )
        var hud = MetalGridHUD()
        hud.stats = stats
        hud.level = level
        hud.totalItems = totalItems
        hud.dataSource = dataSource.label
        onHUD?(hud)
        guard now - lastPerfDiagnosticsLog >= 0.5 else { return }
        lastPerfDiagnosticsLog = now
        PhotoDiagnostics.shared.emit(
            "MetalGridPerf",
            [
                "phase": phase,
                "level": "\(level)",
                "visible": "\(stats.visibleItems)",
                "overscan": "\(stats.overscanItems)",
                "real": "\(stats.realTextureItems)",
                "placeholder": "\(stats.placeholderItems)",
                "drawCalls": "\(stats.drawCalls)",
                "textureBinds": "\(stats.textureBinds)",
                "instances": "\(stats.instanceCount)",
                "drawMs": String(format: "%.2f", stats.drawMs),
                "gpuMs": String(format: "%.2f", stats.gpuMs),
                "uploads": "\(stats.textureUploads)",
                "uploadBytes": "\(stats.textureUploadBytes)",
                "deferredUploads": "\(stats.deferredTextureUploads)",
                "uploadMs": String(format: "%.2f", stats.textureUploadMs),
                "evictions": "\(stats.evictions)",
                "evictMs": String(format: "%.2f", stats.evictMs),
                "residentTextures": "\(stats.residentTextureCount)",
                "pinnedTextures": "\(stats.pinnedTextureCount)",
                "textureCapacity": "\(stats.textureCapacity)",
                "pinnedOverflow": "\(stats.pinnedTextureOverflow)",
                "encodedSlots": "\(stats.encodedSlotItems)",
                "residentMB": String(format: "%.2f", Double(stats.memoryEstimateBytes) / 1_048_576),
                "residentBudgetMB": String(format: "%.0f", Double(stats.residentByteBudget) / 1_048_576),
                "uploadBudgetBytes": "\(stats.uploadByteBudget)",
                "byteBudgetOverflow": "\(stats.byteBudgetOverflow)",
                "residencySaturated": "\(stats.residencySaturated)",
                "effectivePixels": "\(cache.effectiveMaxTexturePixels)",
                "upgrades": "\(cache.upgradesThisFrame)",
                "directUploads": "\(cache.directUploadsThisFrame)",
                "normalizedUploads": "\(cache.normalizedUploadsThisFrame)",
            ])
    }
}
