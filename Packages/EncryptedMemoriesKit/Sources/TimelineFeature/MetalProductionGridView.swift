import AppKit
import GridCore
import MediaCache
import Metal
import PhotosCore
import SwiftUI
import TimelineCore

/// Leading event-inset (in points) for the grid: while a translucent sidebar overlays the grid's leading
/// edge, the host declines hit-testing for `x < inset` so those events reach the sidebar. The grid still
/// renders + lays out full-width (photos animate behind the sidebar). Set by the shell; 0 by default.
public struct GridLeadingEventInsetKey: EnvironmentKey {
    public static let defaultValue: CGFloat = 0
}

public extension EnvironmentValues {
    var gridLeadingEventInset: CGFloat {
        get { self[GridLeadingEventInsetKey.self] }
        set { self[GridLeadingEventInsetKey.self] = newValue }
    }
}

/// The window's translucent toolbar height. The grid bakes it into the engine's top layout margin so the first
/// row rests below the toolbar instead of being tucked under it. Set by the shell; 0 by default.
public struct GridTopBarInsetKey: EnvironmentKey {
    public static let defaultValue: CGFloat = 0
}

public extension EnvironmentValues {
    var gridTopBarInset: CGFloat {
        get { self[GridTopBarInsetKey.self] }
        set { self[GridTopBarInsetKey.self] = newValue }
    }
}

/// The production wrapper around `MetalGridScrollHost` - the Metal-backed library grid (the only timeline
/// grid). The canonical `SquareTileGridEngine` owns all geometry; this adds real-data binding, selection,
/// double-click viewer handoff, zoom-level changes, month labels, badges, and `GridProxy` wiring
/// (windowFrame / scrollToItem / scrollToLatest / zoom).
struct MetalProductionGridView: NSViewRepresentable {
    @Environment(\.gridLeadingEventInset) private var leadingEventInset
    @Environment(\.gridTopBarInset) private var topBarInset
    let sections: [TimelineSection]
    let allItems: [PhotoItem]
    let dataRevision: Int
    let sourceRevision: UInt64
    let feed: ThumbnailFeed
    @Binding var level: Int
    var routeScrollGeneration: Int = 0
    /// The target the next route placement should open at: a remembered photo anchor (returning to a
    /// previously-visited route), or `nil` to open at the newest end (first visit / launch). Set by the shell
    /// alongside `routeScrollGeneration`; consumed once per generation as the host's initial-viewport policy.
    var routeInitialScrollAnchor: GridScrollAnchor<PhotoUID>? = nil
    let gridProfile: GridLevelProfile
    let gridProfileResolver: TimelineGridProfileResolver?
    var gridFillOrder: GridFillOrder = .newestBottomTrailing
    var initialViewportPlacement: TimelineInitialViewportPlacement = .automatic
    let onOpen: (PhotoItem, [PhotoItem]) -> Void
    var proxy: GridProxy<PhotoUID>?
    var selectionMode: Bool = false
    var onSelectionChange: (Set<PhotoUID>) -> Void = { _ in }
    var favoriteUIDs: Set<PhotoUID> = []
    /// Upload badges of pending photos; badge-only changes never rebuild the data source.
    var uploadBadges = PendingUploadBadges.empty
    var media: FullMediaProvider?  // Reserved for drag-to-Finder support.
    var metadataProvider: PhotoMetadataProvider?  // Reserved for richer on-demand metadata.
    /// Drag-out (drag-to-Finder): resolves + stages decrypted originals for the dragged set.
    var dragOutProvider: (any OriginalFileProvider)? = nil
    /// Reports a failed drag-out session (mapped to the shell's shared failure alert).
    var onDragOutFailed: ((DragOutFailureKind) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let coord = context.coordinator
        guard let device = MTLCreateSystemDefaultDevice(),
            let host = MetalGridScrollHost(
                device: device,
                dataSource: MetalGridProductionAdapter.makeDataSource(
                    sections: sections,
                    feed: feed,
                    metadataProvider: metadataProvider
                ),
                gridProfile: gridProfile,
                fillOrder: gridFillOrder,
                gridProfileResolver: gridProfileResolver
            )
        else {
            // Only reachable if Metal can't initialise on this machine (no GPU / shader build fails); emit a
            // diagnostic and return an empty view rather than crash.
            PhotoDiagnostics.shared.emit("MetalGridFallback", ["reason": "hostInitFailed"])
            return NSView()
        }
        host.coordinator.decorationsEnabled = true
        host.eventLeadingInset = leadingEventInset
        host.topBarInset = topBarInset
        coord.host = host
        coord.allItems = allItems
        coord.onOpen = onOpen
        coord.onSelectionChange = onSelectionChange
        coord.onDragOutFailed = onDragOutFailed
        coord.dataRevision = dataRevision
        // A freshly created host opens at its route's initial viewport. At launch (generation 0) the host's
        // default `stickToBottom` already opens at newest, so leave the generation untouched. When the host is
        // (re)created mid-session at a non-zero generation - e.g. returning to a large route after an empty/small
        // one destroyed the host - arm the one-shot policy so a REAL placement happens via the host's layout
        // path, then record the generation as satisfied by THAT placement. The shell sets `routeInitialScrollAnchor`
        // synchronously before the generation bumps, so it is already correct here. This couples "mark applied"
        // to a real placement: `makeNSView` never marks a generation applied without also installing the policy
        // that will place it, so host recreation can't swallow the route placement.
        if routeScrollGeneration != coord.appliedRouteScrollGeneration {
            host.requestInitialViewport(routeInitialViewport)
            coord.appliedRouteScrollGeneration = routeScrollGeneration
        }

        let selection = MetalGridSelectionController()
        let interaction = MetalGridInteractionController(coordinator: host.coordinator, selection: selection)
        interaction.selectionMode = selectionMode
        interaction.onOpen = { [weak coord] uid in
            guard let coord, let item = coord.allItems.first(where: { $0.uid == uid }) else { return }
            coord.onOpen?(item, coord.allItems)
        }
        selection.onChange = { [weak coord] set in
            coord?.host?.coordinator.setSelection(set)
            coord?.a11y?.selected = set
            coord?.onSelectionChange?(set)
        }
        coord.selection = selection
        coord.interaction = interaction
        host.onCellClick = { [weak coord] point, clickCount, modifiers in
            coord?.interaction?.handleClick(contentPoint: point, clickCount: clickCount, modifiers: modifiers)
        }
        host.onMarqueeBegan = { [weak coord] mods in
            coord?.interaction?.handleMarqueeBegan(additive: mods.contains(.shift))
        }
        host.onMarqueeChanged = { [weak coord] rect in
            coord?.interaction?.handleMarqueeChanged(contentRect: rect)
        }
        host.onMarqueeEnded = { [weak coord] in
            coord?.interaction?.handleMarqueeEnded()
        }
        // Drag-out: a threshold-crossing press on a tile starts a native NSFilePromiseProvider
        // dragging session; background presses fall through and the marquee behaves unchanged.
        if let dragOutProvider {
            let dragOut = MetalGridDragOutController(
                spacer: host.documentSpacer,
                coordinator: host.coordinator,
                fileProvider: dragOutProvider,
                itemForUID: { [weak coord] uid in
                    guard let coord else { return nil }
                    return coord.allItems.first(where: { $0.uid == uid })
                },
                liftItems: { [weak coord] pressed in
                    guard let coord else { return [pressed] }
                    let selected = coord.selection?.selected ?? []
                    if selected.contains(pressed.uid), selected.count > 1 {
                        return coord.allItems.filter { selected.contains($0.uid) }
                    }
                    return [pressed]
                },
                onFailed: { [weak coord] kind in coord?.onDragOutFailed?(kind) }
            )
            coord.dragOut = dragOut
            host.onDragOutThreshold = { [weak dragOut] event, contentPoint in
                dragOut?.beginDrag(contentPoint: contentPoint, event: event) ?? false
            }
        }

        let header = MetalGridHeaderRenderer(coordinator: host.coordinator)
        header.overlay.frame = host.bounds
        host.addSubview(header.overlay)  // topmost, transparent to events
        header.markers = MetalGridProductionAdapter.monthMarkers(sections: sections)
        coord.header = header

        let a11y = MetalGridAccessibilityProvider(host: host, coordinator: host.coordinator)
        a11y.items = allItems
        // VoiceOver press activates the cell through the interaction controller so it honours the
        // current selection mode (toggle vs. open), including mode changes after elements were built.
        a11y.onActivate = { [weak interaction] uid in
            interaction?.activate(uid: uid) ?? false
        }
        coord.a11y = a11y

        host.onViewportChanged = { [weak coord] in
            coord?.viewportChanged()
        }

        host.coordinator.setSelectionMode(selectionMode)
        host.coordinator.setFavorites(favoriteUIDs)
        host.coordinator.setUploadBadges(uploadBadges)
        wireProxy(host: host, levelBinding: $level, sourceRevision: sourceRevision)
        host.setLevel(level)
        MetalGridRuntime.logResolutionOnce()
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? MetalGridScrollHost else { return }
        host.eventLeadingInset = leadingEventInset
        host.topBarInset = topBarInset
        host.updateFillOrder(gridFillOrder)
        host.updateGridProfileResolver(gridProfileResolver)
        let coord = context.coordinator
        coord.onOpen = onOpen
        coord.onSelectionChange = onSelectionChange
        coord.onDragOutFailed = onDragOutFailed
        coord.interaction?.selectionMode = selectionMode
        coord.a11y?.selected = host.coordinator.selectedUIDs

        coord.receiveContent(
            items: allItems, revision: dataRevision, routeGeneration: routeScrollGeneration,
            initialViewport: routeInitialViewport,
            markers: MetalGridProductionAdapter.monthMarkers(sections: sections),
            makeSource: {
                MetalGridProductionAdapter.makeDataSource(
                    sections: sections, feed: feed, metadataProvider: metadataProvider)
            })
        host.coordinator.setSelectionMode(selectionMode)
        host.coordinator.setFavorites(favoriteUIDs)
        let previousBadges = host.coordinator.uploadBadges
        host.coordinator.setUploadBadges(uploadBadges)
        // VoiceOver hears the pause on every waiting photo, and only there.
        if MetalGridAccessibilityProvider.badgesChangeLabels(from: previousBadges, to: uploadBadges) {
            coord.a11y?.invalidate()
        }
        // Honour a genuine external (+/- / keyboard / programmatic) level change, but ignore a stale `level`
        // binding value left over from a host-led pinch commit - re-driving it would re-anchor at the viewport
        // centre and jump a different photo under the cursor. See `LevelBindingReconciler`.
        host.reconcileLevelBinding(level)
        wireProxy(host: host, levelBinding: $level, sourceRevision: sourceRevision)
        coord.header?.reposition()
    }

    /// The host initial-viewport policy for the current route: restore a remembered photo anchor, or open at
    /// the newest end when there is none (first visit / launch).
    private var routeInitialViewport: GridInitialViewport {
        if let anchor = routeInitialScrollAnchor {
            return .restore(anchor)
        }
        switch initialViewportPlacement {
        case .automatic:
            return gridFillOrder == .newestBottomTrailing ? .newest : .oldest
        case .newest:
            return .newest
        case .oldest:
            return .oldest
        }
    }

    private func wireProxy(host: MetalGridScrollHost, levelBinding: Binding<Int>, sourceRevision: UInt64) {
        let levelCount = host.coordinator.levelCount  // engine ladder (incl. the larger level 0)
        let stepIn = { [weak host] in
            guard let host else { return }
            host.performDiscreteZoom(to: max(0, host.coordinator.level - 1))
        }
        let stepOut = { [weak host] in
            guard let host else { return }
            host.performDiscreteZoom(to: min(levelCount - 1, host.coordinator.level + 1))
        }
        // Keep the SwiftUI level synchronized with the settled pinch level.
        host.onZoomCommit = { settled in levelBinding.wrappedValue = settled }
        guard let proxy else { return }
        proxy.windowFrameForItem = { [weak host] uid in host?.windowFrame(forUID: uid) }
        proxy.scrollToItem = { [weak host] uid in host?.scrollToItem(uid) }
        proxy.scrollToFlatIndex = { [weak host] index in host?.scrollToFlatIndex(index) }
        proxy.scrollToLatest = { [weak host] in host?.scrollToBottom() }
        proxy.currentScrollAnchor = { [weak host] in host?.currentScrollAnchor() }
        proxy.zoomIn = stepIn
        proxy.zoomOut = stepOut
        // Report the first fully rendered frame to the shell.
        host.coordinator.onContentReady = { [weak proxy] in proxy?.reportContentReady(revision: sourceRevision) }
        // Forward live-resize activity so the shell can suspend expensive overlays.
        host.coordinator.liveResizeChanged = { [weak proxy] active in proxy?.liveResizeChanged?(active) }
        // Forward content-mode changes without changing geometry.
        proxy.toggleContentMode = { [weak host] in host?.coordinator.toggleContentMode() }
        proxy.setContentMode = { [weak host] mode in host?.coordinator.setPreferredNormalLevelContentMode(mode) }
        proxy.contentModeState = { [weak host] in
            guard let c = host?.coordinator else { return (.aspectFitInsideSquare, false) }
            return (c.preferredNormalLevelContentMode, c.aspectToggleAvailable)
        }
    }

    @MainActor final class Coordinator {
        weak var host: MetalGridScrollHost?
        var selection: MetalGridSelectionController?
        var interaction: MetalGridInteractionController?
        var header: MetalGridHeaderRenderer?
        var a11y: MetalGridAccessibilityProvider?
        var allItems: [PhotoItem] = []
        var onOpen: ((PhotoItem, [PhotoItem]) -> Void)?
        var onSelectionChange: ((Set<PhotoUID>) -> Void)?
        var onDragOutFailed: ((DragOutFailureKind) -> Void)?
        var dataRevision = 0
        var appliedRouteScrollGeneration = 0
        private struct OrderUpdate {
            let items: [PhotoItem]
            let revision: Int
            let markers: [(index: Int, text: String)]
            let makeSource: () -> MetalGridDataSource
        }
        private var deferredOrderUpdate: OrderUpdate?

        func receiveContent(
            items: [PhotoItem], revision: Int, routeGeneration: Int,
            initialViewport: GridInitialViewport, markers: [(index: Int, text: String)],
            makeSource: @escaping () -> MetalGridDataSource
        ) {
            guard let host else { return }
            let routePending = routeGeneration != appliedRouteScrollGeneration
            guard revision != dataRevision else {
                if deferredOrderUpdate == nil {
                    allItems = items
                    a11y?.items = items
                }
                return
            }
            if !routePending, deferredOrderUpdate?.revision == revision { return }
            let update = OrderUpdate(items: items, revision: revision, markers: markers, makeSource: makeSource)
            let visible = Set(host.coordinator.visibleCells().map(\.flatIndex))
            let decision: TimelineOrderRefinementPolicy.Decision =
                routePending
                ? .ordinaryUpdate
                : TimelineOrderRefinementPolicy.decision(
                    incoming: items, previousCount: allItems.count, visibleIndices: visible,
                    previous: { uid in host.coordinator.flatIndex(forUID: uid).map { ($0, self.allItems[$0]) } })
            if decision == .deferVisibleCorrection
                || (decision == .applyCorrection && !host.coordinator.canPresentResize)
            {
                deferredOrderUpdate = update
                return
            }
            deferredOrderUpdate = nil
            let viewport =
                routePending
                ? initialViewport
                : (decision == .applyCorrection
                    ? host.currentScrollAnchor().map(GridInitialViewport.restore) ?? .preserve : .preserve)
            apply(update, viewport: viewport, preservesPhase: decision == .applyCorrection)
            if routePending { appliedRouteScrollGeneration = routeGeneration }
        }

        func viewportChanged() {
            if let host, host.coordinator.canPresentResize, let pending = deferredOrderUpdate {
                let visible = Set(host.coordinator.visibleCells().map(\.flatIndex))
                if !TimelineOrderRefinementPolicy.movesVisiblePhoto(
                    incoming: pending.items, visibleIndices: visible, previousUID: { self.allItems[$0].uid })
                {
                    deferredOrderUpdate = nil
                    let viewport = host.currentScrollAnchor().map(GridInitialViewport.restore) ?? .preserve
                    apply(pending, viewport: viewport, preservesPhase: true)
                }
            }
            header?.reposition()
            a11y?.invalidate()
        }

        private func apply(_ update: OrderUpdate, viewport: GridInitialViewport, preservesPhase: Bool) {
            allItems = update.items
            dataRevision = update.revision
            a11y?.items = update.items
            host?.setDataSource(update.makeSource(), initialViewport: viewport, preservingColumnPhase: preservesPhase)
            header?.markers = update.markers
        }

        /// Owns the native drag-out session; created once in `makeNSView` when a provider exists.
        var dragOut: MetalGridDragOutController?
    }
}
