import AlbumCore
import AlbumsFeature
import DesignSystemCore
import Foundation
import GridCore
import MLSearchCore
import MLSearchFeature
import PhotoViewerCore
import PhotosCore
import SwiftUI
import TimelineCore
import TimelineUIKitFeature
import UIKit
import UploadCore

enum MobileTimelineSurface: Equatable {
    case library
    case search

    var title: String {
        switch self {
        case .library: L10n.string("library.title")
        case .search: String(localized: "tab.search")
        }
    }
}

/// The shared library and search timeline. Each native tab owns only its presentation state; both surfaces
/// use the same Metal grid, projection pipeline, selection contract and viewer router.
struct MobileTimelineScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(MobileLibraryModel.self) private var model
    let surface: MobileTimelineSurface
    /// Whether the Photos tab is the active surface. Threaded into the grid so a hidden grid stops its
    /// render loop; defaults to true so previews/other embeds keep the grid live.
    var isActive: Bool = true
    /// Bumped when the active library tab is retapped. The grid observes it and performs the scroll.
    var scrollToLatestSignal: Int = 0
    @Binding private var searchText: String
    @Binding private var searchScope: MLSearchScope
    private let searchLanding: MobileSearchLandingContent
    /// Selected structured suggestion. It owns the result while the field still shows its title.
    private let activeSearchSuggestion: TimelineSearchSuggestion?
    @Environment(MobileViewerRouter.self) private var viewerRouter
    @Environment(MobileSceneContext.self) private var sceneContext
    @State private var selection = MobileGridSelectionController()
    @State private var networkMonitor = NetworkMonitor.shared
    /// Frosted-bar height, read once from the key window and cached. Reading it during `body` would cycle
    /// layout under the safe-area-ignoring overlay.
    @State private var topFrostHeight: CGFloat = mobileTopBarFrostHeightDefault
    // Search uses the same shared coordinator as macOS. Core owns semantic/native execution and
    // rank fusion; this view only commits the resulting UID order to the grid.
    @State private var committedSearchText = ""
    /// The structured suggestion that owned `committedSearchText` when it was committed. It keeps the result
    /// authoritative while an edit of its title is still debouncing.
    @State private var committedSuggestion: TimelineSearchSuggestion?
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var semanticQuery: MLSmartSearchQueryCoordinator?
    /// Identity of the lifecycle the coordinator is bound to - a new session rebinds it.
    @State private var semanticQueryLifecycle: ObjectIdentifier?
    @State private var searchProjection: TimelineSearchProjection?
    @State private var photoNames: PhotoNameIndex?
    @State private var searchCoordinator = TimelineSearchProjectionCoordinator()
    /// Apple-style stacked library refinements. Core evaluates these off-main with AND semantics across
    /// independent groups and OR semantics within the media-kind group.
    @State private var refinement: TimelineRefinement = .all
    @State private var displayMode: TileContentDisplayMode = .squareFillCrop
    @State private var gridProxy = GridProxy<PhotoUID>()
    @State private var searchReturnAnchor: GridScrollAnchor<PhotoUID>?
    @State private var projectionRestoreAnchor: GridScrollAnchor<PhotoUID>?
    @State private var projectionRestoreSignal = 0
    @State private var contentTransitionSignal = 0
    @State private var refinementTopPlacementSignal = 0
    @State private var refinementTopPlacementPending = false
    @State private var searchSessionActive = false
    @State private var contextMenu = MobileGridContextMenuController()
    @State private var showEmptyLibraryBackupSettings = false
    @State private var showAlbumPicker = false
    /// The native toolbar keeps its slots mounted from frame one, but its content appears only after the
    /// launch cover has finished dissolving. This prevents both chrome-over-cover and title relocation.
    @State private var launchChromeVisible = false
    /// Date range of the photos on screen, reported by the grid; shown in the top leading corner for orientation.
    @State private var visibleDatesText: String?
    /// On This Day: the expandable memories area above the library grid, and the photo that "Show in Library" reveals.
    @State private var onThisDay = MobileOnThisDayModel()
    @State private var onThisDayReference = Date()
    @State private var revealUID: PhotoUID?
    @State private var revealSignal = 0
    @State private var revealMissing = false
    @Environment(\.scenePhase) private var scenePhase

    init(
        surface: MobileTimelineSurface = .library,
        isActive: Bool = true,
        scrollToLatestSignal: Int = 0,
        searchText: Binding<String> = .constant(""),
        searchScope: Binding<MLSearchScope> = .constant(.all),
        searchLanding: MobileSearchLandingContent = MobileSearchLandingContent(),
        activeSearchSuggestion: TimelineSearchSuggestion? = nil
    ) {
        self.surface = surface
        self.isActive = isActive
        self.scrollToLatestSignal = scrollToLatestSignal
        _searchText = searchText
        _searchScope = searchScope
        self.searchLanding = searchLanding
        self.activeSearchSuggestion = activeSearchSuggestion
    }

    /// Indicates that a selection action is running, so the other toolbar buttons disable together.
    private var selectionBusy: Bool { selection.isBusy }

    private var canSelect: Bool { model.loadState.isContentReady && !model.items.isEmpty }
    private var backgroundLibraryActivityActive: Bool {
        return model.isBackgroundLoading
    }
    private var connectivityBannerState: LibraryConnectivityBannerState {
        .resolve(
            isOnline: networkMonitor.isOnline,
            didRecentlyRestoreConnection: networkMonitor.didRecentlyRestoreConnection
        )
    }
    private var libraryBannerIsPresented: Bool {
        connectivityBannerState != .hidden || backgroundLibraryActivityActive
    }
    private var libraryBannerMessage: String {
        switch connectivityBannerState {
        case .offline:
            L10n.string("library.title_offline")
        case .connectionRestored:
            L10n.string("library.title_online_restored")
        case .hidden:
            "\(L10n.string("library.title_activity")) …"
        }
    }
    private var libraryBannerVisualState: LibraryActivityBannerState {
        switch connectivityBannerState {
        case .offline:
            .offline
        case .connectionRestored:
            .success
        case .hidden:
            .working
        }
    }

    var body: some View {
        NavigationStack {
            content
                .mobileGridContextMenu(contextMenu, model: model)
                .mobileNavigationTitle(
                    selection.barTitle(default: surface.title),
                    isVisible: launchChromeVisible
                )
                .toolbar { toolbarContent }
                // The UIKit share presenter must stay inside the stack. As a sibling of the NavigationStack it
                // hides the navigation controller from the role-search tab, and iOS falls back to a top drawer
                // field that collapses after the tab is re-entered instead of the bottom field above the keyboard.
                .mobileSharePresentation(selection: selection)
                .mobileSelectionBars(isSelecting: selection.isSelecting)
                .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: selection.isSelecting)
                .onChange(of: searchScope) { _, scope in semanticQuery?.setScope(scope) }
                .onChange(of: searchText) { _, value in scheduleSearchCommit(value) }
                .onChange(of: activeSearchSuggestion) { _, suggestion in
                    // The search tab replaces the selected suggestion with its current version after a library
                    // change. The grid follows it while the committed text still shows its title.
                    guard let suggestion, suggestion.matchingUIDs != nil,
                        committedSuggestion?.id == suggestion.id,
                        suggestion.owns(searchText: normalizedCommittedSearchText)
                    else { return }
                    committedSuggestion = suggestion
                }
                .onDisappear {
                    searchDebounceTask?.cancel()
                    searchDebounceTask = nil
                }
                .task(id: nameQuery) {
                    photoNames = await TimelineFileNameSearchSource.names(forQuery: nameQuery, from: model.backend)
                }
                .task(id: searchProjectionRequest) { await resolveSearchProjection() }
                .onChange(of: hasProjectionCriteria) { _, hasCriteria in
                    guard !hasCriteria else { return }
                    refinementTopPlacementPending = false
                    searchProjection = nil
                    Task { await searchCoordinator.cancel() }
                }
                .task(id: showsLibraryLoadingCover) {
                    if showsLibraryLoadingCover {
                        launchChromeVisible = false
                        return
                    }
                    if reduceMotion {
                        launchChromeVisible = true
                    } else {
                        withAnimation(.easeInOut(duration: LibraryLoadingCoverMetrics.fadeDuration)) {
                            launchChromeVisible = true
                        }
                    }
                }
                .task(id: onThisDayRequest) {
                    guard let request = onThisDayRequest else { return }
                    await onThisDay.refresh(
                        items: model.items, request: request, reference: onThisDayReference, calendar: .current)
                }
                .task { await followOnThisDayCalendar() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { onThisDayReference = Date() }
                }
                .onChange(of: model.facade.map { ObjectIdentifier($0) }) { _, _ in onThisDay.reset() }
                .alert(L10n.string("memories.reveal_missing_title"), isPresented: $revealMissing) {
                    Button(L10n.string("action.ok"), role: .cancel) {}
                } message: {
                    Text(L10n.string("memories.reveal_missing_message"))
                }
        }
        .overlay {
            LibraryActivityBannerOverlay(
                isPresented: libraryBannerIsPresented,
                message: libraryBannerMessage,
                state: libraryBannerVisualState,
                bottomPadding: selection.isSelecting ? 84 : 20,
                isActiveSurface: isActive
            )
        }
        .mobileSelectionAlerts(selection: selection) { performTrash() }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if surface == .library {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    sceneContext.settingsPresented = true
                } label: {
                    Label(String(localized: "library.account_settings"), systemImage: "person.crop.circle")
                }
                .disabled(selection.isSelecting)
                .opacity(launchChromeVisible && !selection.isSelecting ? 1 : 0)
                .allowsHitTesting(launchChromeVisible && !selection.isSelecting)
                .accessibilityLabel(String(localized: "library.account_settings"))
                .accessibilityHidden(!launchChromeVisible || selection.isSelecting)
            }
            .sharedBackgroundVisibility(launchChromeVisible && !selection.isSelecting ? .automatic : .hidden)
            // Also reachable through the Settings command (⌘,), so it may leave a compressed bar first.
            .mobileVisibilityPriority(.low)

            // Mounted from the first frame like the other slots, so the title never relocates when it appears.
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    toggleOnThisDay()
                } label: {
                    Label(
                        L10n.string("memories.title"),
                        systemImage: showsOnThisDayBadge ? "calendar.badge" : "calendar"
                    )
                }
                .disabled(selection.isSelecting || !canSelect)
                .opacity(launchChromeVisible && !selection.isSelecting ? 1 : 0)
                .allowsHitTesting(launchChromeVisible && !selection.isSelecting)
                .accessibilityLabel(L10n.string("memories.title"))
                .accessibilityValue(showsOnThisDayBadge ? L10n.string("memories.unseen") : "")
                .accessibilityAddTraits(onThisDay.isExpanded ? .isSelected : [])
                .accessibilityHidden(!launchChromeVisible || selection.isSelecting)
                .accessibilityIdentifier("library.memories.toggle")
            }
            .sharedBackgroundVisibility(launchChromeVisible && !selection.isSelecting ? .automatic : .hidden)
            .mobileVisibilityPriority(.low)
        }
        // Keep every trailing slot present from the first rendered frame. Adding either control after the
        // library becomes ready makes SwiftUI recompute the semantic `.title` placement and visibly jump it.
        if surface == .library {
            if #available(iOS 27.0, *) {
                // iOS 27: the display options own the slot outside selection. In selection mode the slot leaves the
                // bar and the bulk actions join the system overflow menu (HIG: reserve the ellipsis for overflow).
                // Neither menu is mounted invisibly or empty: a compressed bar could surface a hidden menu, an
                // empty item still paints glass, and UIKit shows the overflow button for any mounted overflow
                // content, which truncated the library title.
                if selection.isSelecting {
                    ToolbarOverflowMenu {
                        selectionOverflowActions
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        libraryOptionsMenu
                            .disabled(!canSelect)
                            .opacity(launchChromeVisible ? 1 : 0)
                            .allowsHitTesting(launchChromeVisible)
                            .accessibilityHidden(!launchChromeVisible)
                    }
                    .sharedBackgroundVisibility(launchChromeVisible ? .automatic : .hidden)
                    // Display options refine the grid; Select/Done outranks them in a compressed bar.
                    .mobileVisibilityPriority(.low)
                }
            } else {
                // iOS 26 has no system overflow menu for these actions, so the slot holds one menu at a time: the
                // display options outside selection and the app-owned bulk-action menu inside it. Keeping both
                // mounted behind opacity reported the hidden menu's label for the bar item and did not stop the
                // 2 pt title shift that the longer selection title causes on iOS 26.5.
                ToolbarItem(placement: .topBarTrailing) {
                    Group {
                        if selection.isSelecting {
                            selectionOptionsMenu
                        } else {
                            libraryOptionsMenu
                        }
                    }
                    .disabled(!canSelect)
                    .opacity(launchChromeVisible ? 1 : 0)
                    .allowsHitTesting(launchChromeVisible)
                    .accessibilityHidden(!launchChromeVisible)
                }
                .sharedBackgroundVisibility(launchChromeVisible ? .automatic : .hidden)
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(selection.isSelecting ? L10n.string("action.done") : L10n.string("action.select")) {
                selection.toggleMode(reduceMotion: reduceMotion)
            }
            .disabled(!canSelect)
            .opacity(launchChromeVisible ? 1 : 0)
            .allowsHitTesting(launchChromeVisible)
            .accessibilityHidden(!launchChromeVisible)
        }
        .sharedBackgroundVisibility(launchChromeVisible ? .automatic : .hidden)
        // Select/Done must stay in the bar on every bar axis: it is the only way to leave selection mode.
        .mobileVisibilityPriority(.high)
        // Keep all item identities mounted. The system can then morph the bar as one native transition.
        MobileSelectionToolbarItems(
            selection: selection,
            canAddToAlbum: model.albumActions?.canAddPhotos == true,
            showAlbumPicker: $showAlbumPicker,
            onShare: startShare,
            onTrash: { selection.showTrashConfirm = true },
            albumPicker: {
                if let coordinator = model.albumActions {
                    AlbumDestinationPicker(
                        coordinator: coordinator,
                        photoUIDs: model.selectedUIDs(selection.selected),
                        onAlbumsChanged: { model.noteAlbumsChanged() },
                        onCompleted: { _ in
                            showAlbumPicker = false
                            selection.finish(reduceMotion: reduceMotion)
                        }
                    )
                }
            }
        )
    }

    private var libraryOptionsMenu: some View {
        Menu {
            Menu {
                LibraryRefinementMenuContent(
                    refinement: refinementBinding,
                    favoritesAvailable: model.favoriteFilterAvailability == .available
                )
            } label: {
                Label(
                    refinement.isActive ? refinement.localizedSummary : L10n.string("library.filter"),
                    systemImage: "line.3.horizontal.decrease"
                )
            }

            Menu {
                let availability =
                    gridProxy.zoomAvailability?()
                    ?? (canZoomIn: false, canZoomOut: false)
                Button {
                    gridProxy.zoomIn?()
                } label: {
                    Label(String(localized: "library.display_zoom_in"), systemImage: "plus.magnifyingglass")
                }
                .disabled(!availability.canZoomIn)

                Button {
                    gridProxy.zoomOut?()
                } label: {
                    Label(String(localized: "library.display_zoom_out"), systemImage: "minus.magnifyingglass")
                }
                .disabled(!availability.canZoomOut)

                Divider()

                Toggle(isOn: aspectRatioGridBinding) {
                    Label(String(localized: "library.display_aspect_grid"), systemImage: "aspectratio")
                }
                .disabled(gridProxy.contentModeState?().toggleAvailable == false)
            } label: {
                Label(String(localized: "library.display_options"), systemImage: "rectangle.grid.3x2")
            }
        } label: {
            Label(String(localized: "library.options"), systemImage: "line.3.horizontal.decrease")
                .foregroundStyle(refinement.isActive ? ProtonColor.primary : ProtonColor.textNorm)
        }
        .accessibilityLabel(String(localized: "library.options"))
        .accessibilityValue(refinement.localizedSummary)
    }

    /// Bulk actions on the selection. iOS 27 places them in the system overflow menu; iOS 26 shows them in the
    /// app-owned ellipsis menu below.
    private var selectionOverflowActions: some View {
        Button {
            toggleSelectedFavorites()
        } label: {
            Label(
                selectedAllFavorited
                    ? String(localized: "viewer.remove_favorite_action")
                    : String(localized: "viewer.favorite_action"),
                systemImage: selectedAllFavorited ? "heart.slash" : "heart"
            )
        }
        .disabled(selection.selected.isEmpty || selectionBusy)
    }

    private var selectionOptionsMenu: some View {
        Menu {
            selectionOverflowActions
        } label: {
            Label(String(localized: "selection.more_a11y"), systemImage: "ellipsis")
        }
        .accessibilityLabel(String(localized: "selection.more_a11y"))
    }

    /// Every change goes through `updateRefinement`, which also places the filtered grid at its first result.
    private var refinementBinding: Binding<TimelineRefinement> {
        Binding(
            get: { refinement },
            set: { next in updateRefinement { $0 = next } }
        )
    }

    private func resetRefinement() {
        updateRefinement { $0 = .all }
    }

    private func updateRefinement(_ update: (inout TimelineRefinement) -> Void) {
        var next = refinement
        update(&next)
        guard next != refinement else { return }
        // A bounded Apple-style filter is a new reading surface, not a temporary replacement of the current
        // full-library viewport. Its newest result starts at top-leading. Clearing every filter returns to the
        // canonical full-library bottom-trailing edge through the fill-order transition below.
        refinementTopPlacementPending = next.isActive
        if !next.isActive {
            contentTransitionSignal &+= 1
        }
        refinement = next
    }

    private var aspectRatioGridBinding: Binding<Bool> {
        Binding(
            get: { displayMode == .aspectFitInsideSquare },
            set: { enabled in
                displayMode = enabled ? .aspectFitInsideSquare : .squareFillCrop
                gridProxy.setContentMode?(displayMode)
            }
        )
    }

    private var selectedAllFavorited: Bool {
        let favorites = model.displayedFavoriteUIDs
        return !selection.selected.isEmpty && selection.selected.allSatisfy(favorites.contains)
    }

    /// The grid keeps the last authoritative projection mounted while a newer query resolves. The expensive
    /// filter/flatten work runs once in TimelineCore, never synchronously from `body`.
    private var visibleItems: [PhotoItem] {
        guard hasProjectionCriteria else { return model.gridItems }
        return (resolvedSearchProjection ?? searchProjection)?.presentationItems ?? model.items
    }

    private var usesTopLeadingProjection: Bool {
        hasSearchQuery || refinement.isActive
    }

    /// Separates full-library and projected identities by parity. The UIKit host can then distinguish a real
    /// content replacement from selection, toolbar and presentation updates without scanning every photo UID.
    private var visibleContentRevision: UInt64 {
        if hasProjectionCriteria, let projection = resolvedSearchProjection ?? searchProjection {
            return projection.revision &* 4 &+ 1
        }
        return model.gridRevision
    }

    private var showsSearchLanding: Bool {
        surface == .search && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder private var content: some View {
        let visibleItems = self.visibleItems
        ZStack(alignment: .topLeading) {
            ProtonColor.backgroundNorm.ignoresSafeArea()

            // The memories area takes real layout space above the grid. The grid keeps its anchor photo at the same
            // distance below the area while it opens or closes, like any other change of its height.
            VStack(spacing: 0) {
                if showsOnThisDayArea {
                    onThisDayArea
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let feed = model.thumbnailFeed, !visibleItems.isEmpty {
                    UIKitTimelineGrid(
                        items: visibleItems,
                        contentRevision: visibleContentRevision,
                        thumbnailFeed: feed,
                        metadataProvider: model.backend,
                        fillOrder: usesTopLeadingProjection ? .topLeading : .newestBottomTrailing,
                        initialViewportPlacement: usesTopLeadingProjection ? .oldest : .automatic,
                        displayMode: displayMode,
                        selectionMode: selection.isSelecting,
                        selectedUIDs: selection.selected,
                        uploadBadges: hasProjectionCriteria ? .empty : model.pendingPresentation.uploadBadges,
                        isActive: isActive && !showsSearchLanding,
                        scrollToLatestSignal: scrollToLatestSignal,
                        scrollToTopSignal: refinementTopPlacementSignal,
                        proxy: gridProxy,
                        restoreScrollAnchor: projectionRestoreAnchor,
                        restoreScrollSignal: projectionRestoreSignal,
                        revealItem: revealUID,
                        revealSignal: revealSignal,
                        contentTransitionSignal: contentTransitionSignal,
                        prefersReducedMotion: reduceMotion,
                        onFirstContentReady: {
                            withAnimation(.spring(duration: 0.55)) { model.markFirstContentReady() }
                        },
                        onVisibleDatesChanged: { visibleDatesText = $0 },
                        onOpenPhoto: open,
                        onToggleSelection: selection.toggle,
                        onSelectionChanged: selection.replace(with:),
                        dragOutProvider: model.backend == nil ? nil : model.viewerMedia,
                        onDragOutFailed: { selection.actionError = MobileSelectionError(message: $0.localizedMessage) },
                        contextMenuActions: { contextMenu.actions(for: $0, model: model) },
                        onContextMenuAction: { action, items in
                            contextMenu.perform(action, items: items, model: model, router: viewerRouter)
                        }
                    )
                    // Extend the scroll surface below the floating navigation and tab bars. The UIKit grid keeps
                    // its safe-area content inset, so only the newest edge exposes protected space below the final
                    // row; as soon as the user scrolls away, thumbnails move naturally beneath Liquid Glass.
                    .ignoresSafeArea(.container, edges: [.top, .horizontal, .bottom])
                    .allowsHitTesting(launchChromeVisible && !showsLibraryLoadingCover && !showsSearchLanding)
                    .accessibilityHidden(!launchChromeVisible || showsLibraryLoadingCover)
                    .accessibilityHidden(showsSearchLanding)
                    .opacity(showsSearchLanding ? 0 : 1)
                }
            }

            // The date label sits below the navigation bar; the open memories area takes that place instead.
            if let visibleDatesText, showsVisibleDates, !showsOnThisDayArea, model.thumbnailFeed != nil,
                !visibleItems.isEmpty
            {
                visibleDatesLabel(visibleDatesText)
            }

            if showsSearchLanding {
                MobileSearchLandingScreen(content: searchLanding)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: showsSearchLanding)
        // Paint status over the resolved content bounds so flexible overlays remain centered.
        .overlay { overlay }
        .overlay(alignment: .top) { TopFrostBar(height: topFrostHeight) }
        .task(id: verticalSizeClass) {
            // Wait until UIKit has committed the new safe-area insets for a rotation before sizing the frost.
            await Task.yield()
            topFrostHeight = mobileTopBarFrostHeight(in: sceneContext)
        }
    }

    /// The date label belongs to a settled grid: not over the launch cover, the search landing or a pending result.
    private var showsVisibleDates: Bool {
        launchChromeVisible && !showsLibraryLoadingCover && !showsSearchLanding && !isProjectionPending
    }

    /// Apple Photos-style orientation label: white bold text over the photos, below the navigation bar.
    private func visibleDatesLabel(_ text: String) -> some View {
        Text(text)
            .font(.title2.bold())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            // The stack keeps the safe area, so the label starts just below the navigation bar.
            .padding(.top, 4)
            .padding(.horizontal, 16)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("library.visibleDates")
            .transition(.opacity)
    }

    private var onThisDayRequest: MobileOnThisDayModel.Request? {
        guard surface == .library else { return nil }
        return MobileOnThisDayModel.Request(
            timelineRevision: model.timelineRevision, reference: onThisDayReference, calendar: .current)
    }

    private var onThisDayAvailability: OnThisDayAvailability {
        guard let request = onThisDayRequest else { return .loading }
        return onThisDay.availability(
            for: request, authority: model.inventoryAuthority, loadFailed: model.loadState.failure != nil)
    }

    private var showsOnThisDayBadge: Bool {
        onThisDayAvailability.showsUnseenBadge(seen: onThisDay.seenRecord)
    }

    private var showsOnThisDayArea: Bool {
        surface == .library && onThisDay.isExpanded && canSelect && launchChromeVisible && !selection.isSelecting
    }

    private var onThisDayArea: some View {
        MobileOnThisDayArea(
            availability: onThisDayAvailability,
            browser: $onThisDay.browser,
            thumbnailFeed: model.thumbnailFeed,
            onOpen: openMemory,
            onShowInLibrary: showInLibrary
        )
    }

    private func toggleOnThisDay() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            onThisDay.isExpanded.toggle()
        }
        if onThisDay.isExpanded { onThisDay.markSeen() }
    }

    /// The memories of one year page in the existing viewer, starting with the card on top of the stack.
    private func openMemory(_ year: OnThisDayYear) {
        viewerRouter.presentation = MobileViewerPresentation(
            index: onThisDay.browser.currentIndex(in: year), items: year.items,
            context: ViewerCollectionContext(filter: .all)
        )
    }

    /// Closes the area and centers the photo in the ordinary library. A filter is removed first, so the photo is in
    /// the grid; a photo that left the library is explained instead of revealing another one.
    private func showInLibrary(_ item: PhotoItem) {
        guard model.gridIndex(of: item.uid) != nil else {
            revealMissing = true
            return
        }
        if refinement.isActive { resetRefinement() }
        revealUID = item.uid
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            onThisDay.isExpanded = false
            revealSignal &+= 1
        }
        AccessibilityNotification.Announcement(L10n.string("memories.shown_in_library")).post()
    }

    /// A new day, time zone or calendar choice selects other memories. The scene's return to the foreground is
    /// handled by `scenePhase`.
    private func followOnThisDayCalendar() async {
        guard surface == .library else { return }
        let names: [Notification.Name] = [
            .NSCalendarDayChanged, .NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification,
        ]
        await withTaskGroup(of: Void.self) { group in
            for name in names {
                group.addTask { @MainActor in
                    for await _ in NotificationCenter.default.notifications(named: name) {
                        onThisDayReference = Date()
                    }
                }
            }
        }
    }

    private var showsLibraryLoadingCover: Bool {
        guard !isProjectionPending, model.loadState.isLoading else { return false }
        return networkMonitor.isOnline || !model.items.isEmpty
    }

    @ViewBuilder private var overlay: some View {
        if !showsSearchLanding {
            ZStack {
                if isProjectionPending {
                    LoadingMark()
                        .frame(width: 64, height: 64)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ProtonColor.backgroundNorm)
                        .transition(.opacity)
                } else if !networkMonitor.isOnline && model.items.isEmpty
                    && (model.loadState.isLoading || model.loadState.failure != nil)
                {
                    OfflineContentUnavailableView()
                } else if model.isCompletelyEmpty && !model.showsPendingPhotos {
                    LibraryEmptyView(backupAction: emptyLibraryBackupAction)
                } else if let failure = model.loadState.failure {
                    MobileLibraryErrorView(message: failure.message, retryable: failure.retryable) {
                        Task { await model.retry() }
                    }
                } else if isEmptySearchResult {
                    // Same empty-search treatment as the macOS timeline.
                    ContentUnavailableView.search(text: committedSearchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isEmptyRefinementResult {
                    ContentUnavailableView {
                        Label(
                            L10n.string("library.filter_empty_title"),
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                    } description: {
                        Text(L10n.string("library.filter_empty_description"))
                    } actions: {
                        Button(L10n.string("library.filter_remove")) {
                            resetRefinement()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .sheet(isPresented: $showEmptyLibraryBackupSettings) {
                if let backup = model.photoBackup {
                    NavigationStack {
                        MobileBackupScreen(
                            controller: backup, uploadCoordinator: model.facade?.uploadCoordinator
                        )
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L10n.string("action.done")) {
                                    showEmptyLibraryBackupSettings = false
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyLibraryBackupAction: LibraryEmptyBackupAction? {
        model.photoBackup.map { backup in
            LibraryEmptyBackupAction(isAvailable: backup.isAvailable, isEnabled: backup.isEnabled) {
                showEmptyLibraryBackupSettings = true
            }
        }
    }

    private func open(_ item: PhotoItem) {
        if !hasProjectionCriteria {
            guard let index = model.gridIndex(of: item.uid) else { return }  // O(1), not an O(n) firstIndex scan
            viewerRouter.presentation = MobileViewerPresentation(
                index: index, items: model.gridItems, context: ViewerCollectionContext(filter: .all),
                followsLibraryReplacements: true
            )
        } else {
            // While searching, the viewer pages through the filtered result set to match macOS. A replacement need
            // not match the search, so this viewer keeps its photos.
            let items = visibleItems
            guard let index = items.firstIndex(where: { $0.uid == item.uid }) else { return }
            viewerRouter.presentation = MobileViewerPresentation(
                index: index, items: items, context: ViewerCollectionContext(filter: .all)
            )
        }
    }

    private var normalizedCommittedSearchText: String {
        committedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The resolved result set of the selected suggestion while the committed text still shows its title.
    private var committedSuggestionMatches: Set<PhotoUID>? {
        guard let committedSuggestion, committedSuggestion.owns(searchText: normalizedCommittedSearchText)
        else { return nil }
        return committedSuggestion.matchingUIDs
    }

    private var hasSearchQuery: Bool {
        committedSuggestionMatches != nil || !TimelineSearchQuery(normalizedCommittedSearchText).isEmpty
    }

    private var hasProjectionCriteria: Bool {
        hasSearchQuery || refinement.isActive
    }

    private var isCommittedSemanticSearchPending: Bool {
        committedSuggestionMatches == nil
            && semanticQuery?.requestedQuery == normalizedCommittedSearchText
            && semanticQuery?.isSearching == true
    }

    private var committedSemanticMatches: Set<PhotoUID>? {
        guard semanticQuery?.resolvedQuery == normalizedCommittedSearchText else { return nil }
        return semanticQuery?.rankedUIDs.map(Set.init)
    }

    /// The text query that file names can match; a structured suggestion has none.
    private var nameQuery: String {
        committedSuggestionMatches == nil ? normalizedCommittedSearchText : ""
    }

    private var searchKey: TimelineSearchProjectionKey {
        if let committedSuggestionMatches {
            // A structured suggestion replaces the text query: its title is display text, not search terms.
            return TimelineSearchProjectionKey(
                sourceRevision: model.timelineRevision,
                query: "",
                context: TimelineSearchContext(favoriteUIDs: model.favoriteUIDs),
                semanticMatches: nil,
                refinement: refinement,
                requiredUIDs: committedSuggestionMatches
            )
        }
        return TimelineSearchProjectionKey(
            sourceRevision: model.timelineRevision,
            query: normalizedCommittedSearchText,
            context: TimelineSearchContext(favoriteUIDs: model.favoriteUIDs, photoNames: photoNames),
            semanticMatches: committedSemanticMatches,
            refinement: refinement
        )
    }

    private var searchProjectionRequest: TimelineSearchProjectionKey? {
        guard hasProjectionCriteria, !isCommittedSemanticSearchPending else { return nil }
        return searchKey
    }

    private var resolvedSearchProjection: TimelineSearchProjection? {
        guard hasProjectionCriteria, searchProjection?.key == searchKey else { return nil }
        return searchProjection
    }

    private var isProjectionPending: Bool {
        hasProjectionCriteria && (isCommittedSemanticSearchPending || resolvedSearchProjection == nil)
    }

    private var isSearchResultPending: Bool {
        hasSearchQuery && isProjectionPending
    }

    private var isEmptySearchResult: Bool {
        hasSearchQuery && !isSearchResultPending && resolvedSearchProjection?.snapshot.isEmpty == true
    }

    private var isEmptyRefinementResult: Bool {
        !hasSearchQuery
            && refinement.isActive
            && !isProjectionPending
            && resolvedSearchProjection?.snapshot.isEmpty == true
    }

    private func resolveSearchProjection() async {
        guard let key = searchProjectionRequest else { return }
        let sections = model.sections
        guard let projection = await searchCoordinator.resolve(sections: sections, key: key),
            !Task.isCancelled,
            searchProjectionRequest == key
        else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            searchProjection = projection
            contentTransitionSignal &+= 1
            if refinementTopPlacementPending, key.refinement == refinement {
                refinementTopPlacementPending = false
                refinementTopPlacementSignal &+= 1
            }
        }
    }

    /// Debounced search commit - the exact macOS pipeline: the semantic coordinator sees every
    /// keystroke (it debounces internally and discards stale epochs), while the committed
    /// lexical query updates after a short pause so the grid never refilters per keystroke.
    private func scheduleSearchCommit(_ value: String) {
        searchDebounceTask?.cancel()
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedValue.isEmpty {
            if searchSessionActive {
                searchSessionActive = false
                projectionRestoreAnchor = searchReturnAnchor
                projectionRestoreSignal &+= 1
            }
        } else if !searchSessionActive {
            // Capture before the debounced query replaces the library projection. Clearing the native search
            // field can then restore the exact photo and sub-row offset the user was looking at.
            searchReturnAnchor = gridProxy.currentScrollAnchor?()
            searchSessionActive = true
        }
        if let smartSearch = model.smartSearch {
            let lifecycle = smartSearch.lifecycleActor
            if semanticQueryLifecycle != ObjectIdentifier(lifecycle) {
                // Bind the coordinator to the lifecycle for this session.
                semanticQuery = MLSmartSearchQueryCoordinator(
                    lifecycle: lifecycle,
                    initialScope: searchScope
                )
                semanticQueryLifecycle = ObjectIdentifier(lifecycle)
            }
        } else {
            semanticQuery = nil
            semanticQueryLifecycle = nil
        }
        if let activeSearchSuggestion, activeSearchSuggestion.matchingUIDs != nil,
            activeSearchSuggestion.owns(searchText: normalizedValue)
        {
            // A selected suggestion already carries its result set. Commit it in the same update, without the
            // typing debounce, so the grid never shows the full library in between; a semantic query for its
            // title would only compete.
            semanticQuery?.clear()
            committedSuggestion = activeSearchSuggestion
            committedSearchText = value
            searchDebounceTask = nil
            return
        }
        semanticQuery?.update(query: value)
        if normalizedValue.isEmpty {
            committedSuggestion = nil
            committedSearchText = ""
            searchDebounceTask = nil
            return
        }
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            committedSuggestion = nil
            committedSearchText = value
            searchDebounceTask = nil
        }
    }

    private func startShare() {
        guard model.backend != nil else { return }
        let chosen = model.selectedItems(selection.selected)  // O(k log k), not an O(n) filter
        // Pending photos share from Apple Photos, every other photo from Proton.
        selection.startShare(items: chosen, backend: model.viewerMedia)
    }

    private func toggleSelectedFavorites() {
        selection.performFavorite { uids in
            await model.toggleFavorite(uids)
        }
    }

    private func performTrash() {
        selection.performTrash { try await model.trashItems($0) }
    }
}

/// Identifiable payload for the viewer sheet - the full item list plus the tapped index, so the viewer can page.
struct MobileViewerPresentation: Identifiable {
    let id = UUID()
    let index: Int
    let items: [PhotoItem]
    let context: ViewerCollectionContext
    var showsInfoInitially = false
    /// The whole-library viewer follows photos that the backup replaced; other collections keep their photos.
    var followsLibraryReplacements = false
    /// A group of duplicates: the viewer shows the merge tools instead of the library actions.
    var duplicateGroup: MobileDuplicateViewerGroup?
}

/// The model that keeps and merges the photos of a viewer of duplicates. The actions find the group of the photo on
/// screen, because the group can split while the viewer is open.
struct MobileDuplicateViewerGroup {
    let model: ExactDuplicatesModel
}

/// A successful viewer mutation removes the current item from the collection that opened it. Filtered grids
/// own their local snapshot, so this tiny presentation event lets them reconcile immediately without a second
/// server fetch or a whole-library scan on the main actor.
struct MobileViewerMutation: Equatable {
    let id = UUID()
    let uid: PhotoUID
}

/// App-wide viewer presentation state, owned above the size-class-adaptive shell. Screens write
/// `presentation`; the single `fullScreenCover` lives in `MobileMainTabView`, so a live iPad window resize
/// may change the underlying shell without dismissing open media.
@MainActor @Observable final class MobileViewerRouter {
    var presentation: MobileViewerPresentation?
    private(set) var completedMutation: MobileViewerMutation?

    func noteCompletedMutation(uid: PhotoUID) {
        completedMutation = MobileViewerMutation(uid: uid)
    }
}

/// Frost height uses the scene window's top inset plus the inline navigation-bar height.
///
/// Read the inset after layout settles; initialization-time reads can trigger a SwiftUI layout cycle under
/// full-bleed overlays.
let mobileTopBarFrostHeightDefault: CGFloat = 91

@MainActor
func mobileTopBarFrostHeight(in scene: MobileSceneContext) -> CGFloat {
    scene.topSafeAreaInset + 44
}
