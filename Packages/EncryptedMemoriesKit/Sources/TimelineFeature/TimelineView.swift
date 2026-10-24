import AppKit
import DesignSystem
import GridCore
import MediaCache
import PhotosCore
import SwiftUI
import TimelineCore

public struct TimelineView: View {
    @State private var model: TimelineViewModel
    /// The AppKit thumbnail feed that wraps `model.feed`; the Metal grid draws its images.
    private let feed: ThumbnailFeed
    @Binding private var level: Int
    /// Leading overlap of the floating sidebar (0 when collapsed). The grid lays its tiles out past this inset
    /// itself, but the SwiftUI placeholder/empty/error states are plain centered views - without this they'd
    /// center over the full detail width (which runs under the sidebar) and read as shifted too far left.
    @Environment(\.gridLeadingEventInset) private var leadingInset: CGFloat
    private let emptyLibraryBackupAction: LibraryEmptyBackupAction?
    private let onOpen: (PhotoItem, [PhotoItem]) -> Void
    private let proxy: GridProxy<PhotoUID>?
    private let routeScrollGeneration: Int
    private let routeInitialScrollAnchor: GridScrollAnchor<PhotoUID>?
    private let searchText: String
    /// True while the semantic engine is resolving the current non-empty query. During this
    /// phase the timeline must not expose lexical fallback content or a premature empty state.
    private let isSearchPending: Bool
    /// UIDs the on-device Smart Search ranked for `searchText` (nil = semantic search inactive).
    private let semanticMatches: Set<PhotoUID>?
    /// Resolved result set of a selected structured suggestion. `searchText` is then its display title only.
    private let requiredUIDs: Set<PhotoUID>?
    /// Library filters (favorites, photos, videos). They narrow the same projection as a search query.
    private let refinement: TimelineRefinement
    private let onClearRefinement: (() -> Void)?
    private let selectionMode: Bool
    private let onSelectionChange: (Set<PhotoUID>) -> Void
    private let media: FullMediaProvider?
    private let metadataProvider: PhotoMetadataProvider?
    private let favoriteUIDs: Set<PhotoUID>
    private let isOffline: Bool
    private let dragOutProvider: (any OriginalFileProvider)?
    private let onDragOutFailed: ((DragOutFailureKind) -> Void)?
    private let gridProfile: GridLevelProfile
    private let gridProfileResolver: TimelineGridProfileResolver?
    private let gridFillOrder: GridFillOrder
    private let initialViewportPlacement: TimelineInitialViewportPlacement
    @State private var searchProjection: TimelineSearchProjection?
    @State private var searchCoordinator: TimelineSearchProjectionCoordinator
    @State private var photoNames: PhotoNameIndex?
    @State private var monthMarkers: [TimelineDateMarker] = []
    @State private var monthMarkerRevision: Int?

    public init(
        model: TimelineViewModel,
        feed: ThumbnailFeed,
        level: Binding<Int>? = nil,
        gridProfile: GridLevelProfile = TimelineGridProfiles.productionDefaultProfile,
        gridFillOrder: GridFillOrder = .newestBottomTrailing,
        initialViewportPlacement: TimelineInitialViewportPlacement = .automatic,
        proxy: GridProxy<PhotoUID>? = nil,
        routeScrollGeneration: Int = 0,
        routeInitialScrollAnchor: GridScrollAnchor<PhotoUID>? = nil,
        searchText: String = "",
        isSearchPending: Bool = false,
        semanticMatches: Set<PhotoUID>? = nil,
        requiredUIDs: Set<PhotoUID>? = nil,
        refinement: TimelineRefinement = .all,
        onClearRefinement: (() -> Void)? = nil,
        selectionMode: Bool = false,
        media: FullMediaProvider? = nil,
        metadataProvider: PhotoMetadataProvider? = nil,
        favoriteUIDs: Set<PhotoUID> = [],
        isOffline: Bool = false,
        dragOutProvider: (any OriginalFileProvider)? = nil,
        onDragOutFailed: ((DragOutFailureKind) -> Void)? = nil,
        emptyLibraryBackupAction: LibraryEmptyBackupAction? = nil,
        onSelectionChange: @escaping (Set<PhotoUID>) -> Void = { _ in },
        onOpen: @escaping (PhotoItem, [PhotoItem]) -> Void = { _, _ in }
    ) {
        _model = State(initialValue: model)
        self.feed = feed
        _level = level ?? .constant(gridProfile.defaultLevel)
        self.gridProfile = gridProfile
        self.gridFillOrder = gridFillOrder
        self.initialViewportPlacement = initialViewportPlacement
        let productionConfig = TimelineGridProfileConfiguration.production
        self.gridProfileResolver = gridProfile == productionConfig.defaultProfile ? productionConfig.resolver : nil
        self.proxy = proxy
        self.routeScrollGeneration = routeScrollGeneration
        self.routeInitialScrollAnchor = routeInitialScrollAnchor
        self.searchText = searchText
        self.isSearchPending = isSearchPending
        self.semanticMatches = semanticMatches
        self.requiredUIDs = requiredUIDs
        self.refinement = refinement
        self.onClearRefinement = onClearRefinement
        self.selectionMode = selectionMode
        self.media = media
        self.metadataProvider = metadataProvider
        self.favoriteUIDs = favoriteUIDs
        self.isOffline = isOffline
        self.dragOutProvider = dragOutProvider
        self.onDragOutFailed = onDragOutFailed
        self.onSelectionChange = onSelectionChange
        self.emptyLibraryBackupAction = emptyLibraryBackupAction
        self.onOpen = onOpen
        _searchProjection = State(initialValue: nil)
        _searchCoordinator = State(initialValue: TimelineSearchProjectionCoordinator())
    }

    public var body: some View {
        Group {
            switch model.gridState {
            case .loading:
                // Route switches (RAW / album / trash …) show the same animated Proton mark as the app's launch
                // veil - never a black surface, never a stale grid. The leading inset keeps the 64pt mark
                // centered in the visible area when the floating sidebar is open.
                if isOffline {
                    OfflineContentUnavailableView()
                        .padding(.leading, leadingInset)
                } else {
                    GridLoadingMark()
                        .padding(.leading, leadingInset)
                }
            case .empty:
                emptyState
                    .padding(.leading, leadingInset)
            case .failed(let message):
                if isOffline {
                    OfflineContentUnavailableView()
                        .padding(.leading, leadingInset)
                } else {
                    errorState(message)
                        .padding(.leading, leadingInset)
                }
            case .loaded:
                let showsMonthLabels = gridProfile.showsMonthLabels(level: level)
                ZStack(alignment: .trailing) {
                    if isEmptySearchResult {
                        searchEmptyState
                            .padding(.leading, leadingInset)
                    } else if !displayedItems.isEmpty {
                        MetalProductionGridView(
                            sections: displayedSections,
                            allItems: displayedItems,
                            dataRevision: gridDataRevision,
                            sourceRevision: model.gridSourceRevision,
                            feed: feed,
                            level: $level,
                            routeScrollGeneration: routeScrollGeneration,
                            routeInitialScrollAnchor: routeInitialScrollAnchor,
                            gridProfile: gridProfile,
                            gridProfileResolver: gridProfileResolver,
                            gridFillOrder: gridFillOrder,
                            initialViewportPlacement: initialViewportPlacement,
                            onOpen: onOpen,
                            proxy: proxy,
                            selectionMode: selectionMode,
                            onSelectionChange: onSelectionChange,
                            favoriteUIDs: favoriteUIDs,
                            uploadBadges: hasSearchQuery ? .empty : model.pendingUploadBadges,
                            media: media,
                            metadataProvider: metadataProvider,
                            dragOutProvider: dragOutProvider,
                            onDragOutFailed: onDragOutFailed
                        )
                        .ignoresSafeArea(edges: .bottom)

                        if showsMonthLabels,
                            monthMarkerRevision == gridDataRevision,
                            monthMarkers.count > 1
                        {
                            TimelineDateScrubber(markers: monthMarkers) { marker in
                                proxy?.scrollToFlatIndex?(marker.index)
                            }
                        }
                    }

                    if isSearchResultPending {
                        LoadingMark()
                            .frame(width: 64, height: 64)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.leading, leadingInset)
                            .background(timelineSurfaceBackground)
                            .transition(.opacity)
                    }
                }
            }
        }
        .background(timelineSurfaceBackground)
        .task { await model.load() }
        .task(id: projectionQuery) {
            photoNames = await TimelineFileNameSearchSource.names(forQuery: projectionQuery, from: metadataProvider)
        }
        .task(id: searchProjectionRequest) { await resolveSearchProjection() }
        .task(id: markerRequest) { await resolveMonthMarkers(for: markerRequest) }
        .onChange(of: hasSearchQuery) { _, hasQuery in
            guard !hasQuery else { return }
            searchProjection = nil
            Task { await searchCoordinator.cancel() }
        }
        .onAppear { MetalGridRuntime.logResolutionOnce() }
    }

    private var timelineSurfaceBackground: Color {
        Color(nsColor: MetalGridPalette.background)
    }

    private var emptyState: some View {
        LibraryEmptyView(filter: model.filter, backupAction: emptyLibraryBackupAction)
            .background(timelineSurfaceBackground)
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label(L10n.string("error.load_library_title"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
                .textSelection(.enabled)
        } actions: {
            RetryButton(.prominent) { Task { await model.retry() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(timelineSurfaceBackground)
    }

    @ViewBuilder
    private var searchEmptyState: some View {
        if requiredUIDs == nil, TimelineSearchQuery(normalizedSearchText).isEmpty, refinement.isActive {
            ContentUnavailableView {
                Label(L10n.string("library.filter_empty_title"), systemImage: "line.3.horizontal.decrease")
            } description: {
                Text(L10n.string("library.filter_empty_description"))
            } actions: {
                if let onClearRefinement {
                    Button(L10n.string("library.filter_remove"), action: onClearRefinement)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(timelineSurfaceBackground)
        } else {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(timelineSurfaceBackground)
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the grid shows a projection instead of the library: a search query, a suggestion, or a filter.
    private var hasSearchQuery: Bool {
        requiredUIDs != nil || !TimelineSearchQuery(normalizedSearchText).isEmpty || refinement.isActive
    }

    /// A structured suggestion replaces the text query: its title is display text, not search terms.
    private var projectionQuery: String {
        requiredUIDs == nil ? normalizedSearchText : ""
    }

    private var searchKey: TimelineSearchProjectionKey {
        TimelineSearchProjectionKey(
            sourceRevision: model.contentRevision,
            query: projectionQuery,
            context: TimelineSearchContext(
                activeFilter: model.filter, favoriteUIDs: favoriteUIDs, photoNames: photoNames),
            semanticMatches: requiredUIDs == nil ? semanticMatches : nil,
            refinement: refinement,
            requiredUIDs: requiredUIDs
        )
    }

    private var searchProjectionRequest: TimelineSearchProjectionKey? {
        guard hasSearchQuery, !isSearchPending else { return nil }
        return searchKey
    }

    private var resolvedSearchProjection: TimelineSearchProjection? {
        guard hasSearchQuery, searchProjection?.key == searchKey else { return nil }
        return searchProjection
    }

    private var displayedSections: [TimelineSection] {
        if gridFillOrder == .topLeading {
            let items = displayedItems
            guard let first = items.first else { return [] }
            // The Metal data source and viewer must consume the same cached presentation order.
            return [TimelineSection(id: "grid-presentation", date: first.captureTime, title: "", items: items)]
        }
        guard hasSearchQuery else { return model.gridSections }
        return (resolvedSearchProjection ?? searchProjection)?.sections ?? model.currentSections
    }

    private var displayedItems: [PhotoItem] {
        guard hasSearchQuery else { return model.gridItems }
        return (resolvedSearchProjection ?? searchProjection)?.presentationItems ?? model.presentationItems
    }

    private var isSearchResultPending: Bool {
        hasSearchQuery && (isSearchPending || resolvedSearchProjection == nil)
    }

    private var isEmptySearchResult: Bool {
        hasSearchQuery && !isSearchResultPending && resolvedSearchProjection?.snapshot.isEmpty == true
    }

    private var gridDataRevision: Int {
        if hasSearchQuery, let projection = resolvedSearchProjection ?? searchProjection {
            return Int(truncatingIfNeeded: projection.revision &* 2 &+ 1)
        }
        return Int(truncatingIfNeeded: model.gridSourceRevision &* 2)
    }

    private var markerRequest: TimelineMarkerRequest {
        TimelineMarkerRequest(
            dataRevision: gridDataRevision,
            showsMonthLabels: gridProfile.showsMonthLabels(level: level)
        )
    }

    private func resolveSearchProjection() async {
        guard let key = searchProjectionRequest else { return }
        let sections = model.currentSections
        guard let projection = await searchCoordinator.resolve(sections: sections, key: key),
            !Task.isCancelled,
            searchProjectionRequest == key
        else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            searchProjection = projection
        }
    }

    private func resolveMonthMarkers(for request: TimelineMarkerRequest) async {
        guard request.showsMonthLabels else {
            monthMarkers = []
            monthMarkerRevision = request.dataRevision
            return
        }
        monthMarkerRevision = nil
        let items = displayedItems
        let task = Task.detached(priority: .userInitiated) {
            MetalGridProductionAdapter.dateMarkers(items: items, granularity: .month)
        }
        let markers = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled, markerRequest == request else { return }
        monthMarkers = markers
        monthMarkerRevision = request.dataRevision
    }
}

private struct TimelineMarkerRequest: Hashable {
    let dataRevision: Int
    let showsMonthLabels: Bool
}

private struct TimelineDateScrubber: View {
    let markers: [TimelineDateMarker]
    let onJump: (TimelineDateMarker) -> Void

    @State private var activeIndex: Int?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geometry in
            let active = activeIndex.flatMap { markers[safe: $0] }
            ZStack(alignment: .trailing) {
                Color.clear
                    .frame(width: hovering || active != nil ? 7 : 4)
                    .glassEffect(in: Capsule(style: .continuous))
                    .opacity(hovering || active != nil ? 0.72 : 0.22)
                    .padding(.trailing, 10)

                if let active, let index = activeIndex {
                    Text(active.text)
                        .font(.system(size: 13, weight: .semibold))
                        // Regular Liquid Glass flips its content between light and dark over the photos.
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(in: Capsule(style: .continuous))
                        .position(
                            x: geometry.size.width - 66,
                            y: markerY(index: index, height: geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = markerIndex(at: value.location.y, height: geometry.size.height)
                        guard activeIndex != index, let marker = markers[safe: index] else { return }
                        activeIndex = index
                        onJump(marker)
                    }
                    .onEnded { _ in activeIndex = nil }
            )
            .onHover { hovering = $0 }
        }
        .frame(width: hovering || activeIndex != nil ? 112 : 32)
        .padding(.trailing, 8)
        .padding(.vertical, 96)
        .allowsHitTesting(markers.count > 1)
    }

    private func markerIndex(at y: CGFloat, height: CGFloat) -> Int {
        guard markers.count > 1 else { return 0 }
        let normalized = min(max(y / max(height, 1), 0), 1)
        return min(markers.count - 1, max(0, Int((normalized * CGFloat(markers.count)).rounded(.down))))
    }

    private func markerY(index: Int, height: CGFloat) -> CGFloat {
        guard markers.count > 1 else { return height / 2 }
        let q = CGFloat(index) / CGFloat(markers.count - 1)
        return min(max(12, q * height), max(12, height - 12))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
