import AlbumCore
import AlbumsFeature
import AppKit
import CoreLocation
import DesignSystem
import DesignSystemCore
import GridCore
import MLSearchCore
import MLSearchFeature
import MapFeature
import MediaByteCache
import MediaCache
import MediaLocationCore
import PhotoLibraryBackupAdapter
import PhotoViewerFeature
import PhotosCore
import ProtonDriveBackend
import SwiftUI
import TimelineCore
import TimelineFeature
import UniformTypeIdentifiers
import UploadCore
import UploadFeature

struct MainView: View {
    @AppStorage(AppSettingsKey.mapAndPlacesEnabled) private var mapAndPlacesEnabled =
        AppSettingsDefault.mapAndPlacesEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager

    let model: AppModel
    let facade: ProtonClientFacade
    let backend: any PhotosBackend
    @Bindable var uploadCoordinator: UploadCoordinator

    @State private var timelineModel: TimelineViewModel
    @State private var mapClusterModel: TimelineViewModel
    @State private var viewerModel: PhotoViewerModel?
    /// Set when the viewer opens: only a viewer of the whole library without search or filter follows replacements.
    @State private var viewerFollowsReplacements = false
    @State private var level: Int = 3  // 0 is largest; 5 is the densest overview.
    @State private var temporalMode: TimelineTemporalMode = .allPhotos
    /// Library filters of the Mediathek, shared with iPhone and iPad through `LibraryRefinementMenuContent`.
    @State private var refinement: TimelineRefinement = .all
    @State private var temporalProjection = TimelineTemporalProjection.loading(mode: .years)
    @State private var focusedTemporalYear: Int?
    // Levels L0-L3 use this content mode. Overview levels always crop to a square.
    @State private var gridContentMode: TileContentDisplayMode = .aspectFitInsideSquare

    /// Suspends the title-bar frost while the Metal surface is being scaled during resize.
    @State private var gridLiveResizeActive = false
    @State private var sidebarOpen: Bool
    @State private var sidebarWidth: CGFloat
    @State private var columnVisibility: NavigationSplitViewVisibility  // native sidebar show/hide
    @State private var restoredInitialSidebarVisibility = false
    private let initiallyShowsSidebar: Bool
    @State private var albums: [AlbumSummary] = []
    @State private var albumCatalogFailed = false
    @State private var albumLoadGeneration: UInt64 = 0
    @State private var albumActions: AlbumActionCoordinator
    @State private var showCreateAlbum = false
    @State private var showAlbumDestination = false
    @State private var selection: PhotoFilter = .all
    @State private var mapClusterPresentation: MapClusterPresentation?
    /// The Duplicates route of this account. Nil while the account cannot merge duplicates.
    @State private var duplicates: ExactDuplicatesModel?
    @State private var confirmsDuplicateMergeAll = false
    @State private var mapClusterPageIndex = 0
    @State private var mapClusterRouteGeneration = 0
    @State private var routeScrollGeneration = 0
    /// Stores a layout-independent photo anchor for each visited route.
    /// Routes without an anchor open at the newest photo.
    @State private var routeScrollPositions: [PhotoFilter: GridScrollAnchor<PhotoUID>] = [:]
    /// Holds the initial anchor for the current route generation.
    /// Route changes set it before loading sections.
    @State private var routeInitialScrollAnchor: GridScrollAnchor<PhotoUID>? = nil
    @State private var searchText = ""
    @State private var committedSearchText = ""
    /// Debounced, epoch-guarded semantic query pipeline (shared Core). Created once Smart Search
    /// is configured; publishes ranked UIDs the timeline widens its lexical results with.
    @State private var semanticQuery: MLSmartSearchQueryCoordinator?
    @State private var searchScope: MLSearchScope = .all
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var searchHistory = TimelineSearchHistory()
    private var searchDiscovery: SmartSearchDiscoveryModel { model.searchSuggestions.discovery }
    @State private var searchActivity: LibraryRuntimeActivityRegistration?
    /// The structured suggestion that owned `committedSearchText` when it was committed.
    @State private var committedSuggestion: TimelineSearchSuggestion?
    /// A search text that may be a suggestion title, held until a current refresh decides how to run it.
    @State private var pendingSuggestionText: String?
    /// Bounds the wait for `pendingSuggestionText`; cancelled when the text changes or is decided.
    @State private var pendingSuggestionDeadlineTask: Task<Void, Never>?
    // Shared-element transition between a photo and its grid cell.
    @State private var gridProxy = GridProxy<PhotoUID>()
    @State private var mapClusterGridProxy = GridProxy<PhotoUID>()
    /// The timeline content revision whose visible frame the Metal host has fully drawn. The shared load-state
    /// policy may present a non-empty cached revision while Proton validation continues in the background.
    @State private var renderedLibraryRevision: UInt64?
    @State private var veilSettleTask: Task<Void, Never>?
    @State private var zoom: ZoomTransition?
    // Real height of the native window toolbar (its top safe-area inset). The viewer lays its media out
    // below this, so the open/close zoom must fly the photo into the SAME region to avoid a shrink/jump.
    @State private var topBarInset: CGFloat = 0
    @State private var networkMonitor = NetworkMonitor.shared
    // The floating sidebar width is the grid's leading obstruction. Keep it stable during resize so geometry
    // is not recomputed per frame.
    private var leadingObstructionInset: CGFloat { columnVisibility == .detailOnly ? 0 : sidebarWidth }
    /// The sidebar's show and hide timing. Every surface that follows the sidebar uses it, like the grid's
    /// `MetalGridScrollHost`: two different curves lay the window out for the longer one and let the viewer trail.
    private static let sidebarAnimation = Animation.easeInOut(duration: 0.22)
    // Selection + export.
    @State private var selectionMode = false
    @State private var selectedUIDs: Set<PhotoUID> = []
    @State private var isExporting = false
    /// 0…1 download progress for the top-bar ring (blended across all selected items).
    @State private var exportFraction: Double = 0
    /// The running export, so the progress menu can cancel it mid-download (partial ZIP is discarded).
    @State private var exportTask: Task<Void, Never>?
    @State private var confirmLargeExport = false
    @State private var pendingExportItems: [PhotoItem] = []
    @State private var pendingExportZipName: String?
    /// Above this many selected items, downloading a ZIP asks for confirmation first.
    private let largeExportThreshold = 50
    @State private var pendingTrashItems: [PhotoItem] = []
    @State private var closeViewerAfterTrash = false
    @State private var confirmTrash = false
    @State private var confirmAlbumPhotoAction = false
    @State private var confirmEmptyTrash = false
    @State private var isTrashMutating = false
    @State private var isEmptyingTrash = false
    @State private var isSavingToLibrary = false
    @State private var confirmDeleteAlbum = false
    @State private var isDeletingAlbum = false
    @State private var albumDeleteFailureMessage: String?
    @State private var albumCoverFailureMessage: String?
    @State private var isSettingAlbumCover = false
    @State private var exportFailureTitle: String?
    @State private var exportFailureMessage: String?
    /// Set when a trash/restore API call fails. Local projections change only after server success, so a
    /// failed request never needs to reconstruct optimistic state or risks showing a false success.
    @State private var trashActionFailureMessage: String?
    @State private var albumMembershipFailureMessage: String?
    /// A failed drag-out (drag-to-Finder) staging session, surfaced through the shared alert surface.
    @State private var dragOutFailureMessage: String?
    // Favorites (read from server so iOS favorites show up; toggle writes back).
    private var favorites: Set<PhotoUID> { favoriteState.favorites }
    private var favoritesLoaded: Bool { favoriteState.availability == .available }
    @State private var favoriteState = FavoriteState()
    /// Offers to undo the last delete of photos that were not backed up yet.
    @State private var undoNotice: UndoNoticeContent?
    /// Refresh routes and the library activity banner state.
    @State private var libraryRefresh = MacLibraryRefreshController()
    private let libraryChangeMonitor = LibraryChangeMonitor()
    private let feed: ThumbnailFeed
    private let temporalCoverImageLoader: TimelineTemporalCoverImageLoader
    private let zoomOpenSpring = (response: 0.34, damping: 0.86)
    private let zoomCloseSpring = (response: 0.32, damping: 0.88)

    init(model: AppModel, facade: ProtonClientFacade) {
        self.model = model
        self.facade = facade
        self.backend = facade.backend
        self.uploadCoordinator = facade.uploadCoordinator
        _albumActions = State(initialValue: AlbumActionCoordinator(repository: facade.albums))
        // Learned thumbnail dimensions persist into the library metadata DB (photos.w/h) through the
        // backend bridge - batched by the coalescer, so decode callbacks never touch the DB directly.
        let dimensions = PhotoDimensionCoalescer(store: backend)
        // Use the SHARED, account-configured cache (AppModel.prepareBackend calls
        // OfflineLibraryManager.shared.configure(session:) before this view is built) so the encrypted
        // disk cache uses the durable per-account session-derived key and survives relaunch. A fresh
        // ThumbnailCache() here would stay on a per-process ephemeral key and re-crawl the whole library
        // every launch.
        let feed = ThumbnailFeed(
            cache: OfflineLibraryManager.shared.cache,
            loader: facade.librarySources,
            dimensions: dimensions
        )
        self.feed = feed
        self.temporalCoverImageLoader = TimelineTemporalCoverImageLoader(
            media: backend,
            previewCache: OfflineLibraryManager.shared.previewCache,
            originalsCache: OfflineLibraryManager.shared.originalsCache
        )
        _timelineModel = State(
            initialValue: TimelineViewModel(repository: backend, feed: feed.feedCore, library: backend))
        _mapClusterModel = State(
            initialValue: TimelineViewModel(repository: backend, feed: feed.feedCore, library: backend))
        let sidebarVisible = SidebarPersistence.resolvedVisible()
        let width = SidebarPersistence.resolvedWidth()
        initiallyShowsSidebar = sidebarVisible
        // Always mount the native sidebar column once. Starting NavigationSplitView directly in `.detailOnly`
        // leaves AppKit's navigation toolbar item at x=22, underneath the traffic lights, until the first real
        // sidebar toggle. Restore the persisted visibility after the first rendered revision, while the launch
        // cover is still up, so AppKit establishes the native sidebar/titlebar geometry first.
        _sidebarOpen = State(initialValue: true)
        _sidebarWidth = State(initialValue: width)
        _columnVisibility = State(initialValue: .all)
    }

    var body: some View {
        ZStack {
            // NATIVE shell: NavigationSplitView gives the macOS-26 floating Liquid-Glass sidebar (native title,
            // toggle, glass to the top corner) for free. The detail's Metal grid extends UNDER the floating
            // sidebar via `.ignoresSafeArea(.container, edges: [.top, .leading])`, while its content is laid out
            // only in the unobscured area (the leading-obstruction inset = the detail's leading safe-area inset).
            synchronizedToolbar {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView(
                        albums: albums,
                        isLoadingAlbums: albumActions.showsInitialAlbumLoadingPlaceholder,
                        albumCatalogFailed: albumCatalogFailed,
                        sharedAlbums: albumActions.sharedAlbums,
                        sharedAlbumPresentation: albumActions.presentation(for:),
                        isLoadingSharedAlbums: albumActions.showsInitialSharedAlbumLoadingPlaceholder,
                        sharedAlbumCatalogFailed: albumActions.sharedLoadErrorMessage != nil,
                        canLeaveSharedAlbum: albumActions.canLeaveSharedAlbum,
                        canCreateAlbum: albumActions.canCreate,
                        canAddPhotos: albumActions.canAddPhotos && !albumActions.isWorking,
                        thumbnailFeed: feed,
                        sourceAnalysisRevision: model.sourceAnalysisRevision,
                        showsDuplicates: duplicates != nil,
                        duplicateCount: duplicates?.knownDuplicateCount,
                        selection: $selection,
                        onRetryAlbums: { Task { await loadAlbums() } },
                        onRetrySharedAlbums: { Task { await albumActions.refreshSharedAlbums() } },
                        onLeaveSharedAlbum: { album in
                            Task { _ = await albumActions.leaveSharedAlbum(album) }
                        },
                        onCreateAlbum: { presentCreateAlbum() },
                        onDropPhotos: { album, uids in
                            Task { await addDroppedPhotos(uids, to: album) }
                        }
                    )
                    // Fixed width. (The OS still draws a resize cursor on the divider even though the column is not
                    // user-resizable - an AppKit quirk we accept; min==ideal==max did not change it.)
                    .navigationSplitViewColumnWidth(sidebarWidth)
                } detail: {
                    libraryDetail
                }
            }
            .task(id: model.albumCatalogRevision) { await loadAlbums() }
            .task(id: ObjectIdentifier(facade)) { await installDuplicates() }
            .onAppear {
                attachOfflineManager()
                attachPendingGrid()
                AppMemoryPressureCoordinator.shared.attachFeed(feed)
                gridProxy.onContentReady = { revision in
                    renderedLibraryRevision = revision
                    timelineModel.markInitialContentReady()
                    evaluateVeilLift()
                }
                gridProxy.liveResizeChanged = { @MainActor [state = self.$gridLiveResizeActive] active in
                    state.wrappedValue = active
                }
                evaluateVeilLift()
            }
            .onChange(of: librarySettled) { _, _ in evaluateVeilLift() }
            .onChange(of: timelineModel.contentRevision) { _, _ in evaluateVeilLift() }
            // Split out of this chain: inline, the added handlers exceed the type-checker's time budget.
            .applying { searchDiscoveryLifecycle($0) }
            .applying { mapAndPlacesLifecycle($0) }
            .applying { viewerFollowLifecycle($0) }
            .task(id: temporalProjectionRequestID) {
                await rebuildTemporalProjection()
            }
            .onChange(of: libraryRefresh.isBusy) { _, _ in evaluateVeilLift() }
            .onChange(of: selection) { oldValue, newValue in
                selectionMode = false
                selectedUIDs.removeAll()
                if newValue != .all {
                    temporalMode = .allPhotos
                    focusedTemporalYear = nil
                }
                if newValue != .map {
                    mapClusterPresentation = nil
                }
                // Switching sidebar route while a photo/video is open: close the viewer INSTANTLY so the new tab's
                // grid (or Map) just shows. No zoom-back-to-cell - the photo's cell usually isn't in the new
                // route, and the expectation is simply "tab switches, photo closes."
                if viewerModel != nil {
                    zoom = nil
                    viewerModel = nil
                }
                // Remember where the user was in the route they're leaving (the grid still shows it at this
                // point, so the proxy reports the OLD route's anchor). Returning to that route re-pins it.
                if let anchor = gridProxy.currentScrollAnchor?() {
                    routeScrollPositions[oldValue] = anchor
                }
                // Non-timeline routes (for example the Map overlay) keep the last grid route underneath.
                guard newValue.hasTimeline else { return }
                // Set the route anchor and generation before loading route data. The host consumes the one-shot
                // placement when geometry is valid.
                routeInitialScrollAnchor = routeScrollPositions[newValue]
                routeScrollGeneration += 1
                Task { await timelineModel.select(newValue) }
            }
            .onChange(of: model.pendingTrash.localUIDs) { _, _ in
                timelineModel.setPendingTrash(model.pendingTrash)
            }
            .onChange(of: timelineModel.wholeLibraryContentRevision) { _, _ in
                model.pendingGrid?.setRemote(timelineModel.wholeLibraryTimeline)
                let items = timelineModel.wholeLibraryItemsForViewer
                OfflineLibraryManager.shared.liveAssetCount = items.count
                // Kick off the low-priority GPS crawl (once) so the Map's location index fills in behind the
                // thumbnail crawl.
                OfflineLibraryManager.shared.startLocationCrawl(items: items, metadata: backend)
                // New/removed assets flow into the Smart Search index on its next background pass.
                model.updateSmartSearchAssets(
                    items,
                    authority: timelineModel.wholeLibraryInventoryAuthority
                )
            }
            .onChange(of: timelineModel.wholeLibraryInventoryAuthorityRevision) { _, _ in
                model.updateSmartSearchAssets(
                    timelineModel.wholeLibraryItemsForViewer,
                    authority: timelineModel.wholeLibraryInventoryAuthority
                )
            }
            .onDisappear(perform: handleDisappear)
            .onChange(of: columnVisibility) { _, newValue in
                // The NATIVE split-view toggle drives columnVisibility - mirror it back into our open-state +
                // persistence (the ⌥⌘S path goes through toggleSidebar() which sets both).
                let visible = newValue != .detailOnly
                guard visible != sidebarOpen else { return }
                sidebarOpen = visible
                SidebarPersistence.saveVisible(visible)
            }
            .onReceive(NotificationCenter.default.publisher(for: .encryptedMemoriesToggleSidebar)) { _ in
                toggleSidebar()
            }
            .onAppear {
                // The menu command shows ⌥⌘S; the key itself must bypass AppKit's hidden sidebar item.
                SidebarToggleShortcut.install {
                    NotificationCenter.default.post(name: .encryptedMemoriesToggleSidebar, object: nil)
                }
            }
            .onChange(of: networkMonitor.didRecentlyRestoreConnection) { _, restored in
                if restored {
                    retryAfterConnectivityRestored()
                }
            }
            .task { await uploadCoordinator.start() }
            .task { await startLibraryChangeMonitor() }
            .onReceive(NotificationCenter.default.publisher(for: .encryptedMemoriesUploadPhotos)) { notification in
                performUploadUIAction("uploadPhotos", trigger: uploadTrigger(from: notification))
            }
            .onReceive(NotificationCenter.default.publisher(for: .encryptedMemoriesUploadFolder)) { notification in
                performUploadUIAction("uploadFolder", trigger: uploadTrigger(from: notification))
            }
            .onReceive(NotificationCenter.default.publisher(for: .encryptedMemoriesShowUploadQueue)) { notification in
                performUploadUIAction("showQueue", trigger: uploadTrigger(from: notification))
            }
            .onReceive(NotificationCenter.default.publisher(for: .encryptedMemoriesNewAlbum)) { _ in
                presentCreateAlbum()
            }
            .onReceive(NotificationCenter.default.publisher(for: .encryptedMemoriesRefreshLibrary)) { _ in
                refreshLibraryManually()
            }
            .onChange(of: uploadCoordinator.completedUploadRevision) { _, _ in
                guard let completed = uploadCoordinator.latestCompletedUpload else { return }
                scheduleUploadRefresh(completed)
            }
            .onChange(of: model.photoBackupController?.uploadedLibraryMutationRevision) { _, _ in
                scheduleLibraryRefreshAfterBackupUpload()
            }
            .sheet(isPresented: $uploadCoordinator.isDestinationSheetPresented) {
                UploadDestinationSheet(coordinator: uploadCoordinator)
            }

            // Library Map route. Match the other library routes with a plain unavailable surface until the
            // location index contains a place; rendering an empty world map only adds visual noise.
            if selection == .map && mapAndPlacesEnabled {
                let locationIndex = OfflineLibraryManager.shared.locationIndex
                Group {
                    if locationIndex.coordinates.isEmpty {
                        mapEmptyState
                    } else {
                        LibraryMapScreen(
                            index: locationIndex,
                            thumbnail: { feed.memoryImage(for: $0) },
                            loadThumbnail: { await feed.cachedImage(for: $0) },
                            onSelectPhoto: { openPhotoByUID($0) },
                            onSelectCluster: { uids, coordinate in showMapCluster(uids: uids, coordinate: coordinate) })
                    }
                }
                .padding(.leading, leadingObstructionInset)
                .animation(Self.sidebarAnimation, value: leadingObstructionInset)
                .ignoresSafeArea()
            }

            if selection == .duplicates, let duplicates {
                MacDuplicatesView(
                    model: duplicates,
                    thumbnailFeed: feed,
                    sourceAnalysisRevision: model.sourceAnalysisRevision,
                    topInset: topBarInset,
                    confirmsMergeAll: $confirmsDuplicateMergeAll
                )
                .padding(.leading, leadingObstructionInset)
                .animation(Self.sidebarAnimation, value: leadingObstructionInset)
                .ignoresSafeArea()
            }

            if selection == .map, mapClusterPresentation != nil {
                TimelineView(
                    model: mapClusterModel,
                    feed: feed,
                    level: $level,
                    gridFillOrder: .topLeading,
                    initialViewportPlacement: .oldest,
                    proxy: mapClusterGridProxy,
                    routeScrollGeneration: mapClusterRouteGeneration,
                    routeInitialScrollAnchor: nil,
                    searchText: committedSearchText,
                    isSearchPending: isCommittedSemanticSearchPending,
                    semanticMatches: committedSemanticMatches,
                    requiredUIDs: committedSuggestionMatches,
                    selectionMode: selectionMode,
                    media: backend,
                    metadataProvider: backend,
                    favoriteUIDs: favorites,
                    isOffline: !networkMonitor.isOnline,
                    dragOutProvider: backend,
                    onDragOutFailed: { dragOutFailureMessage = $0.localizedMessage },
                    onSelectionChange: { selectedUIDs = $0 }
                ) { item, items in
                    openPhoto(item, items, proxy: mapClusterGridProxy)
                }
                // This root-ZStack sibling sits above the NavigationSplitView, unlike its detail-hosted primary
                // grid. Move the whole surface beside the floating sidebar and keep the Metal host's local
                // obstruction at zero so the sidebar is neither covered nor applied twice.
                .padding(.leading, leadingObstructionInset)
                .animation(Self.sidebarAnimation, value: leadingObstructionInset)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .environment(\.gridTopBarInset, topBarInset)
                .transition(.opacity)
            }

            // Keep the viewer mounted during interactive dismissal so its pinch gesture remains active.
            if let viewerModel, zoom == nil || zoom?.interactive == true {
                PhotoViewerView(
                    model: viewerModel,
                    onClose: { closePhoto() },
                    onPinchDismissBegan: beginInteractiveDismiss,
                    onPinchDismissChanged: updateInteractiveDismiss,
                    onPinchDismissEnded: { endInteractiveDismiss(shouldClose: $0) },
                    isDismissing: zoom?.interactive == true
                )
                // Keep the viewer beside the floating sidebar. The inset matches the zoom overlay's content rect.
                .padding(.leading, leadingObstructionInset)
                .animation(Self.sidebarAnimation, value: leadingObstructionInset)  // slide with the sidebar toggle
                // Do not hide the view with opacity while dismissing. Keep it hit-testable so the gesture cannot
                // reach the grid behind it.
            }

            // Shared-element zoom overlay: a single image morphing between the cell and fullscreen.
            if let zoom { zoomOverlay(zoom) }

            uploadRefreshBanner

            UndoNoticeOverlay(
                notice: $undoNotice, bottomPadding: 64, leadingObstructionInset: leadingObstructionInset)
        }
        .background(
            // Reads the real top safe-area inset (= native toolbar height) so the zoom transition and the
            // viewer agree on exactly where the media sits below the opaque top bar.
            GeometryReader { geo in
                Color.clear
                    .onAppear { topBarInset = geo.safeAreaInsets.top }
                    .onChange(of: geo.safeAreaInsets.top) { _, new in topBarInset = new }
            }
        )
        .coordinateSpace(name: "root")
        .animation(Self.sidebarAnimation, value: sidebarOpen)
        .sheet(isPresented: $showCreateAlbum) {
            AlbumCreationSheet(
                coordinator: albumActions,
                onAlbumsChanged: { Task { await loadAlbums() } },
                onCompleted: { _ in showCreateAlbum = false }
            )
        }
        .alert(trashConfirmationTitle, isPresented: $confirmTrash) {
            Button("alert.move_to_trash", role: .destructive) {
                let items = pendingTrashItems
                let shouldClose = closeViewerAfterTrash
                pendingTrashItems = []
                closeViewerAfterTrash = false
                trashPhotos(items, closeViewer: shouldClose)
            }
            Button(L10n.string("action.cancel"), role: .cancel) {
                pendingTrashItems = []
                closeViewerAfterTrash = false
            }
        } message: {
            Text(trashConfirmationMessage)
        }
        .confirmationDialog(
            L10n.string("albums.remove_photos_title"),
            isPresented: $confirmAlbumPhotoAction,
            titleVisibility: .visible
        ) {
            Button(L10n.string("albums.remove_photos_action")) { removeSelectedFromCurrentAlbum() }
            Button(L10n.string("albums.move_photos_to_trash"), role: .destructive) { trashSelected() }
            Button(L10n.string("action.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("albums.remove_photos_message"))
        }
        .alert(L10n.string("trash.empty_title"), isPresented: $confirmEmptyTrash) {
            Button(L10n.string("trash.empty_confirm"), role: .destructive) {
                emptyTrash()
            }
            Button(L10n.string("action.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("trash.empty_message"))
        }
        .alert(L10n.string("albums.delete_title"), isPresented: $confirmDeleteAlbum) {
            Button(L10n.string("albums.delete_action"), role: .destructive) { deleteCurrentAlbum() }
            Button(L10n.string("action.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("albums.delete_message"))
        }
        .alert("export.confirm_many_title", isPresented: $confirmLargeExport) {
            Button("export.confirm_many_button") {
                let items = pendingExportItems
                let zipName = pendingExportZipName
                pendingExportItems = []
                pendingExportZipName = nil
                startExport(items, zipSuggestedName: zipName)
            }
            Button(L10n.string("action.cancel"), role: .cancel) {
                pendingExportItems = []
                pendingExportZipName = nil
            }
        } message: {
            Text("export.confirm_many_message \(pendingExportItems.count)")
        }
        .alert(
            "alert.trash_action_failed_title",
            isPresented: Binding(
                get: { trashActionFailureMessage != nil },
                set: { if !$0 { trashActionFailureMessage = nil } }
            )
        ) {
            Button(L10n.string("action.ok"), role: .cancel) { trashActionFailureMessage = nil }
        } message: {
            Text(trashActionFailureMessage ?? "")
        }
        .alert(
            L10n.string("dragout.error.title"),
            isPresented: Binding(
                get: { dragOutFailureMessage != nil },
                set: { if !$0 { dragOutFailureMessage = nil } }
            )
        ) {
            Button(L10n.string("action.ok"), role: .cancel) { dragOutFailureMessage = nil }
        } message: {
            Text(dragOutFailureMessage ?? "")
        }
        .alert(
            L10n.string("albums.remove_photos_failed_title"),
            isPresented: Binding(
                get: { albumMembershipFailureMessage != nil },
                set: { if !$0 { albumMembershipFailureMessage = nil } }
            )
        ) {
            Button(L10n.string("action.ok"), role: .cancel) { albumMembershipFailureMessage = nil }
        } message: {
            Text(albumMembershipFailureMessage ?? "")
        }
        .alert(
            L10n.string("albums.delete_failed_title"),
            isPresented: Binding(
                get: { albumDeleteFailureMessage != nil },
                set: { if !$0 { albumDeleteFailureMessage = nil } }
            )
        ) {
            Button(L10n.string("action.ok"), role: .cancel) { albumDeleteFailureMessage = nil }
        } message: {
            Text(albumDeleteFailureMessage ?? "")
        }
        .alert(
            "albums.cover_failed_title",
            isPresented: Binding(
                get: { albumCoverFailureMessage != nil },
                set: { if !$0 { albumCoverFailureMessage = nil } }
            )
        ) {
            Button(L10n.string("action.ok"), role: .cancel) { albumCoverFailureMessage = nil }
        } message: {
            Text(albumCoverFailureMessage ?? "")
        }
        .alert(
            albumActions.actionFailure?.title ?? "",
            isPresented: Binding(
                get: { albumActions.actionFailure != nil },
                set: { if !$0 { albumActions.clearActionFailure() } }
            )
        ) {
            Button(L10n.string("action.ok"), role: .cancel) {
                albumActions.clearActionFailure()
            }
        } message: {
            Text(albumActions.actionFailure?.message ?? "")
        }
        .alert(
            Text(exportFailureTitle ?? ""),
            isPresented: Binding(
                get: { exportFailureMessage != nil },
                set: {
                    if !$0 {
                        exportFailureTitle = nil
                        exportFailureMessage = nil
                    }
                }
            )
        ) {
            Button(L10n.string("action.ok"), role: .cancel) {
                exportFailureTitle = nil
                exportFailureMessage = nil
            }
        } message: {
            Text(exportFailureMessage ?? "")
        }
    }

    private func handleDisappear() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        clearPendingSuggestionText()
        cancelVeilTasks()
        libraryRefresh.cancelBackupUploadRefresh()
        let changeMonitor = libraryChangeMonitor
        Task { await changeMonitor.stop() }
    }

    private var libraryDetail: some View {
        Group {
            if showsTemporalBrowser {
                TimelineTemporalBrowser(
                    projection: temporalProjection,
                    thumbnailFeed: feed,
                    coverImageLoader: temporalCoverImageLoader,
                    focusedYear: focusedTemporalYear,
                    onSelectYear: selectTemporalYear,
                    onOpenPhotos: { item, items in openPhoto(item, items, proxy: nil) }
                )
                // The temporal browser is a SwiftUI surface rather than the Metal grid, so it must consume the
                // floating sidebar obstruction explicitly. Keep its visible content and hit targets beside the
                // sidebar while the shared root still extends beneath the native title bar.
                .padding(.leading, leadingObstructionInset)
                .animation(reduceMotion ? nil : Self.sidebarAnimation, value: leadingObstructionInset)
                .transition(.opacity)
            } else {
                TimelineView(
                    model: timelineModel,
                    feed: feed,
                    level: $level,
                    gridFillOrder: gridFillOrder,
                    proxy: gridProxy,
                    routeScrollGeneration: routeScrollGeneration,
                    routeInitialScrollAnchor: routeInitialScrollAnchor,
                    searchText: committedSearchText,
                    isSearchPending: isCommittedSemanticSearchPending,
                    semanticMatches: committedSemanticMatches,
                    requiredUIDs: committedSuggestionMatches,
                    refinement: activeRefinement,
                    onClearRefinement: { applyRefinement(.all) },
                    selectionMode: selectionMode,
                    media: backend,
                    metadataProvider: backend,
                    favoriteUIDs: displayedFavorites,
                    isOffline: !networkMonitor.isOnline,
                    dragOutProvider: media,
                    onDragOutFailed: { dragOutFailureMessage = $0.localizedMessage },
                    onSelectionChange: { selectedUIDs = $0 },
                    onOpen: { item, items in
                        openPhoto(item, items, proxy: nil, followsReplacements: showsUnfilteredLibrary)
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: temporalMode)
        .ignoresSafeArea(.container, edges: [.top, .leading])
        .overlay(alignment: .top) {
            if viewerModel == nil {
                TopFrostBar(height: topBarInset + 12)
                    .opacity(gridLiveResizeActive ? 0 : 1)
                    .animation(.easeInOut(duration: 0.12), value: gridLiveResizeActive)
            }
        }
        .navigationTitle(viewerModel == nil ? title : "")
        .smartSearchToolbar(
            text: $searchText,
            scope: $searchScope,
            availableScopes: model.smartSearch?.availableSearchScopes ?? [.all],
            isEnabled: model.smartSearch?.snapshot.isSearchAvailable == true,
            isVisible: viewerModel == nil,
            placement: .toolbar,
            prompt: Text(L10n.string("search.prompt \(title)")),
            recentSearches: searchHistory.queries,
            suggestions: searchDiscovery.textSuggestions(
                content: searchDiscoveryContent,
                snapshot: model.smartSearch?.snapshot
            ).map {
                SmartSearchSuggestionItem(id: $0.id, title: $0.title, query: $0.query)
            },
            isUpdatingSuggestions: model.searchSuggestions.isRefreshing,
            onClearRecentSearches: clearSearchHistory
        )
        .onSubmit(of: .search) { recordSearchHistory(searchText) }
        .onChange(of: searchScope) { _, scope in semanticQuery?.setScope(scope) }
        // Keep the native Liquid Glass toolbar. The real insets keep grid and viewer geometry aligned.
        .environment(\.gridLeadingEventInset, leadingObstructionInset)
        .environment(\.gridTopBarInset, topBarInset)
        .onChange(of: searchText) { _, value in scheduleSearchCommit(value) }
    }

    /// Native upload menu for the system toolbar.
    private var uploadToolbarMenu: some View {
        Menu {
            Button("menu.upload_photos") { performUploadUIAction("uploadPhotos", trigger: .toolbar) }
                .disabled(!uploadCoordinator.uploadCapabilities.canUpload)
            Button("menu.upload_folder") { performUploadUIAction("uploadFolder", trigger: .toolbar) }
                .disabled(!uploadCoordinator.uploadCapabilities.canUpload)
            Divider()
            Button("menu.show_uploads") { performUploadUIAction("showQueue", trigger: .toolbar) }
        } label: {
            Label("toolbar.upload", systemImage: "tray.and.arrow.up")
        }
        .help("toolbar.upload_menu_help")
        .accessibilityLabel("toolbar.upload")
        .popover(isPresented: $uploadCoordinator.isQueueVisible, arrowEdge: .top) {
            UploadQueuePanel(coordinator: uploadCoordinator)
        }
    }

    /// Native toolbar menu for actions on the selected album.
    private var albumActionsToolbarMenu: some View {
        Menu {
            Button(selectionMode ? L10n.string("action.done") : L10n.string("action.select")) {
                selectionMode.toggle()
                if !selectionMode { selectedUIDs.removeAll() }
            }
            Divider()
            Button(L10n.string("albums.delete_action"), role: .destructive) {
                confirmDeleteAlbum = true
            }
            .disabled(isDeletingAlbum || !facade.albums.capabilities.canDelete)
        } label: {
            Label(L10n.string("albums.more_actions"), systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .help(L10n.string("albums.more_actions"))
        .accessibilityLabel(L10n.string("albums.more_actions"))
    }

    /// Adds photos dropped on a sidebar album. The drop can land while another album change finishes; it waits for
    /// that change instead of losing the photos, and says so if the change does not finish.
    private func addDroppedPhotos(_ uids: [PhotoUID], to album: AlbumSummary) async {
        // Decide now whether the drag carried the selection: the add can wait, and the selection can change meanwhile.
        let droppedSelection = selectedUIDs.isEmpty || Set(uids) != selectedUIDs ? nil : selectedUIDs
        var waitedIntervals = 0
        while albumActions.isWorking, waitedIntervals < 300 {  // at most 30 seconds
            try? await Task.sleep(for: .milliseconds(100))
            waitedIntervals += 1
        }
        if await albumActions.add(uids, to: album.id) {
            // The toolbar's feedback: the added selection ends, unless the person selected something else meanwhile.
            if let droppedSelection, selectedUIDs == droppedSelection { endSelection() }
            await loadAlbums()
        } else if albumActions.actionFailure == nil {
            albumActions.actionFailure = AlbumActionFailure(
                title: L10n.string("albums.add_failed_title"),
                message: L10n.string("albums.add_busy_message")
            )
        }
    }

    /// The grid's feedback after the selection joined an album: the selection ends.
    private func endSelection() {
        selectionMode = false
        selectedUIDs.removeAll()
    }

    /// Opens the shared name form.
    private func presentCreateAlbum() {
        guard albumActions.canCreate else { return }
        showCreateAlbum = true
    }

    /// Reuses one toolbar region for download progress or the Trash restore action.
    @ViewBuilder private var downloadActionItem: some View {
        if isExporting {
            exportProgressIndicator
            exportCancelButton
        } else if selection == .trash {
            Button {
                restoreSelected()
            } label: {
                if selectedUIDs.isEmpty {
                    Image(systemName: "arrow.uturn.backward")
                } else {
                    Label("\(selectedUIDs.count)", systemImage: "arrow.uturn.backward")
                }
            }
            .disabled(selectedUIDs.isEmpty || isTrashMutating)
            .help("toolbar.restore_from_trash")
            .accessibilityLabel(
                selectedUIDs.isEmpty
                    ? "a11y.restore_selected_from_trash" : "a11y.restore_count_from_trash \(selectedUIDs.count)")
        } else {
            Button {
                downloadSelected()
            } label: {
                if selectedUIDs.isEmpty {
                    Image(systemName: "square.and.arrow.down")
                } else {
                    Label("\(selectedUIDs.count)", systemImage: "square.and.arrow.down")
                }
            }
            .disabled(selectedUIDs.isEmpty)
            .help(
                selectedUIDs.count > 1
                    ? "toolbar.download_count_photos_help \(selectedUIDs.count)" : "toolbar.download_original"
            )
            .accessibilityLabel(
                selectedUIDs.isEmpty
                    ? "a11y.download_selected_originals"
                    : "a11y.download_count_selected_originals \(selectedUIDs.count)")
        }
    }

    /// Determinate export progress paired with a separate cancellation control.
    private var exportProgressIndicator: some View {
        let pct = Int((exportFraction * 100).rounded())
        return ExportProgressRing(fraction: exportFraction)
            .help("export.progress_percent \(pct)")
            .accessibilityElement()
            .accessibilityLabel("export.progress_percent \(pct)")
    }

    private var exportCancelButton: some View {
        Button {
            cancelExport()
        } label: {
            Label("export.cancel", systemImage: "xmark")
                .labelStyle(.iconOnly)
        }
        .help("export.cancel")
        .accessibilityLabel("export.cancel")
    }

    private var uploadRefreshBanner: some View {
        let connectivityState = LibraryConnectivityBannerState.resolve(
            isOnline: networkMonitor.isOnline,
            didRecentlyRestoreConnection: networkMonitor.didRecentlyRestoreConnection
        )
        let hasUploadMessage = libraryRefresh.message != nil
        let backgroundVisible = backgroundLibraryActivityActive && viewerModel == nil && selection.hasTimeline
        let connectivityVisible = connectivityState != .hidden
        let message: String
        let visualState: LibraryActivityBannerState
        switch connectivityState {
        case .offline:
            message = L10n.string("library.title_offline")
            visualState = .offline
        case .connectionRestored:
            message = L10n.string("library.title_online_restored")
            visualState = .success
        case .hidden:
            message = libraryRefresh.message ?? "\(L10n.string("library.title_activity")) …"
            // While a refresh runs, the banner shows work, as before; the message decides the colour once it ends.
            switch hasUploadMessage && !libraryRefresh.isBusy ? libraryRefresh.tone : .working {
            case .success: visualState = .success
            case .failure: visualState = .failure
            case .working, nil: visualState = .working
            }
        }
        return LibraryActivityBannerOverlay(
            isPresented: connectivityVisible || hasUploadMessage || backgroundVisible,
            message: message,
            state: visualState,
            leadingObstructionInset: leadingObstructionInset
        )
    }

    // MARK: - Zoom transition

    private struct MapClusterPresentation {
        let title: String
        let coordinate: CLLocationCoordinate2D
        let pager: PhotoLocationClusterPager
    }

    private struct ZoomTransition: Equatable {
        let item: PhotoItem
        let image: NSImage
        var cellFrame: CGRect
        var progress: CGFloat  // 1 = fullscreen, 0 = collapsed into the grid cell
        var interactive: Bool  // true = pinch-driven (the viewer is kept alive, invisible, behind this overlay)
    }

    @ViewBuilder private func zoomOverlay(_ z: ZoomTransition) -> some View {
        GeometryReader { geo in
            // This layer uses window coordinates to match the cell frames.
            // The content rectangle excludes the top bar and floating sidebar.
            let contentRect = CGRect(
                x: leadingObstructionInset, y: topBarInset,
                width: max(0, geo.size.width - leadingObstructionInset),
                height: max(0, geo.size.height - topBarInset))
            let full = fitRect(z.image, in: contentRect)
            let p = max(0, min(1, z.progress))
            let frame = Self.lerpRect(z.cellFrame, full, p)
            ZStack {
                ViewerVisualConstants.backgroundColor.opacity(p)  // Reveals the grid as the photo shrinks.
                    .padding(.leading, leadingObstructionInset)  // Covers only the detail area.
                Image(nsImage: z.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private static func lerpRect(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    /// Open the viewer for a photo identified only by uid (a Map pin tap). Looks it up in the currently loaded
    /// library list and opens directly (no cell-zoom - the grid cell is behind the map / may be off-screen).
    private func openPhotoByUID(_ uid: PhotoUID) {
        let items = timelineModel.wholeLibraryItemsForViewer
        guard let item = timelineModel.allLibraryItem(matching: uid) else { return }
        openPhoto(item, items)
    }

    private func showMapCluster(uids: [PhotoUID], coordinate: CLLocationCoordinate2D) {
        let orderedUIDs = timelineModel.allLibraryUIDs(matching: Set(uids))
        let pager = PhotoLocationClusterPager(uids: Array(orderedUIDs.reversed()))
        guard let firstPage = pager.page(at: 0), !firstPage.uids.isEmpty else { return }
        selectionMode = false
        selectedUIDs = []
        viewerModel = nil
        zoom = nil
        mapClusterPresentation = MapClusterPresentation(
            title: L10n.string("map.cluster_title"),
            coordinate: coordinate,
            pager: pager
        )
        mapClusterPageIndex = 0
        routeInitialScrollAnchor = nil
        loadMapClusterPage(firstPage.index)
    }

    private func loadMapClusterPage(_ index: Int) {
        guard let presentation = mapClusterPresentation,
            let page = presentation.pager.page(at: index)
        else { return }
        let items = timelineModel.allLibraryItems(matching: Set(page.uids))
        selectionMode = false
        selectedUIDs = []
        mapClusterPageIndex = index
        mapClusterRouteGeneration += 1
        let sectionID = "map-cluster-\(mapClusterRouteGeneration)"
        Task {
            await mapClusterModel.showTransientItems(items, sectionID: sectionID)
        }
    }

    private func closeMapCluster() {
        selectionMode = false
        selectedUIDs = []
        mapClusterPresentation = nil
    }

    private var activeGridProxy: GridProxy<PhotoUID> {
        mapClusterPresentation == nil ? gridProxy : mapClusterGridProxy
    }

    private func openPhoto(
        _ item: PhotoItem, _ items: [PhotoItem], proxy: GridProxy<PhotoUID>? = nil, followsReplacements: Bool = false
    ) {
        viewerFollowsReplacements = followsReplacements
        // Need the cell's on-screen frame and a thumbnail to fly; otherwise just open directly.
        let sourceProxy = proxy ?? activeGridProxy
        guard let cell = sourceProxy.windowFrameForItem?(item.uid), let img = feed.memoryImage(for: item.uid) else {
            viewerModel = makeViewer(item, items)
            return
        }
        zoom = ZoomTransition(item: item, image: img, cellFrame: cell, progress: 0, interactive: false)
        DispatchQueue.main.async {
            withAnimation(.spring(response: zoomOpenSpring.response, dampingFraction: zoomOpenSpring.damping)) {
                zoom?.progress = 1
            } completion: {
                viewerModel = makeViewer(item, items)
                zoom = nil
            }
        }
    }

    // MARK: Interactive pinch-to-dismiss

    /// Starts live dismissal toward the viewer's grid cell. Keeps the viewer mounted for gesture delivery.
    private func beginInteractiveDismiss() {
        // A new pinch supersedes an interactive dismissal. Preserve only a non-interactive open/close spring;
        // otherwise the gesture owns resolution.
        if let z = zoom, !z.interactive { return }
        guard let vm = viewerModel, let img = vm.image,
            let target = viewerReturnTarget(for: vm)
        else { return }
        zoom = ZoomTransition(item: target.item, image: img, cellFrame: target.cell, progress: 1, interactive: true)
    }

    /// Live pinch progress: 1 = fullscreen, 0 = collapsed into the cell.
    private func updateInteractiveDismiss(_ progress: CGFloat) {
        guard zoom?.interactive == true else { return }
        zoom?.progress = max(0, min(1, progress))
    }

    /// Fingers up: commit the close (fly the rest of the way into the cell) or spring back to fullscreen.
    private func endInteractiveDismiss(shouldClose: Bool) {
        guard zoom?.interactive == true else { return }
        zoom?.interactive = false  // Allows the viewer to hide after the gesture ends.
        DispatchQueue.main.async {
            withAnimation(.spring(response: zoomCloseSpring.response, dampingFraction: zoomCloseSpring.damping)) {
                zoom?.progress = shouldClose ? 0 : 1
            } completion: {
                if shouldClose { viewerModel = nil }
                zoom = nil
            }
        }
    }

    private func closePhoto() {
        guard let vm = viewerModel else { return }
        // Fly back to the photo's ACTUAL cell. If it scrolled off-screen (user navigated), close
        // instantly rather than centre-scrolling (which made it always shrink into the middle).
        guard let img = vm.image, let target = viewerReturnTarget(for: vm) else {
            viewerModel = nil
            return
        }
        zoom = ZoomTransition(item: target.item, image: img, cellFrame: target.cell, progress: 1, interactive: false)
        DispatchQueue.main.async {
            withAnimation(.spring(response: zoomCloseSpring.response, dampingFraction: zoomCloseSpring.damping)) {
                zoom?.progress = 0
            } completion: {
                viewerModel = nil
                zoom = nil
            }
        }
    }

    private func viewerReturnTarget(for vm: PhotoViewerModel) -> (item: PhotoItem, cell: CGRect)? {
        let preferredProxy = activeGridProxy
        for item in vm.gridReturnCandidates {
            if let cell = preferredProxy.windowFrameForItem?(item.uid) { return (item, cell) }
        }
        if mapClusterPresentation != nil {
            for item in vm.gridReturnCandidates {
                if let cell = gridProxy.windowFrameForItem?(item.uid) { return (item, cell) }
            }
        }
        return nil
    }

    private func makeViewer(_ item: PhotoItem, _ items: [PhotoItem]) -> PhotoViewerModel {
        let index = items.firstIndex(of: item) ?? 0
        let offline = OfflineLibraryManager.shared
        // Pending photos that are not in Proton yet open from Apple Photos; everything else from Proton.
        let media = self.media
        return PhotoViewerModel(
            items: items, index: index, feed: feed, media: media,
            streamer: media, metadataProvider: media,
            albumMembershipProvider: facade.albums,
            placeNameResolver: NativePlaceNameResolver.shared,
            knownLocationUIDs: Set(offline.locationIndex.coordinates.map(\.uid)),
            burstProvider: backend,
            previewCache: offline.previewCache,
            originalsCache: offline.originalsCache,
            cacheOriginals: offline.offlineEnabled,
            originalsCapBytes: offline.originalsCapBytes)
    }

    /// Shows local photos on their way to Proton in the whole-library grid.
    private func attachPendingGrid() {
        guard let session = model.pendingGrid else { return }
        session.attachFeed(
            timelineModel.feed, imageRequest: PhotoKitPlatformImages.request, fileThumbnails: folderMedia)
        session.presenter.onChange = { [timelineModel] presentation in
            timelineModel.setPendingPresentation(presentation)
        }
        timelineModel.setPendingPresentation(session.presenter.current)
        timelineModel.setPendingTrash(model.pendingTrash)
        session.setRemote(timelineModel.wholeLibraryTimeline)
    }

    /// Favorites as the app shows them: Proton favorites plus the intents of pending photos.
    private var displayedFavorites: Set<PhotoUID> {
        _ = model.pendingFavoriteRevision
        return model.pendingGrid?.displayedFavorites(favorites) ?? favorites
    }

    /// Pending files of the watched backup folders.
    private var folderMedia: PendingFolderMedia? {
        model.backupController.map { PendingFolderMedia(access: $0.pendingAccess) }
    }

    /// Viewer, export and drag-out media: pending photos from Apple Photos, every other photo from Proton.
    private var media: LocalPendingMediaRouter {
        LocalPendingMediaRouter(
            remote: backend, remoteVideo: backend, imageRequest: PhotoKitPlatformImages.request, files: folderMedia)
    }

    /// Takes photos that are not backed up yet out of the backup; they stay in Apple Photos. The deletion can
    /// be undone from the notice and with Edit > Undo.
    private func excludeFromBackup(_ uids: [PhotoUID]) async -> Bool {
        guard let session = model.pendingGrid, await session.delete(uids) else { return false }
        let undo: @MainActor () -> Void = { [weak session] in
            guard let session else { return }
            Task { await session.restore(uids) }
        }
        undoManager?.registerUndo(withTarget: model) { _ in undo() }
        undoManager?.setActionName(L10n.string("pending.delete_notice"))
        undoNotice = UndoNoticeContent(message: L10n.string("pending.delete_notice"), systemImage: "icloud.slash") {
            [undoManager] in
            undoManager?.removeAllActions(withTarget: model)
            undo()
        }
        return true
    }

    /// Registers this window's thumbnail feed with the shared offline-cache manager, so the Settings
    /// scene can delete the cache and read status. The thumbnail crawl is mandatory grid infrastructure,
    /// independent of the Offline Photo Library toggle.
    private func attachOfflineManager() {
        let manager = OfflineLibraryManager.shared
        manager.attach(feed: feed, stats: backend)
        manager.liveAssetCount = timelineModel.wholeLibraryUIDs.count
        model.configureSmartSearch(
            feedCore: feed.feedCore,
            primaryItems: timelineModel.wholeLibraryItemsForViewer,
            primaryAuthority: timelineModel.wholeLibraryInventoryAuthority,
            onPrimaryInventoryFailure: { timelineModel.reportInitialContentFailure() }
        )
    }

    /// Aspect-fit rect of `image` centred in `size` - the photo's fullscreen frame.
    private func fitRect(_ image: NSImage, in size: CGSize) -> CGRect {
        let ia = image.size.width / max(image.size.height, 1)
        let ra = size.width / max(size.height, 1)
        var w = size.width
        var h = size.height
        if ia > ra { h = w / ia } else { w = h * ia }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Aspect-fit rect of `image` centred within an arbitrary `rect` (used to fit inside the media region
    /// below the top bar, not the whole window).
    private func fitRect(_ image: NSImage, in rect: CGRect) -> CGRect {
        let fitted = fitRect(image, in: rect.size)
        return fitted.offsetBy(dx: rect.minX, dy: rect.minY)
    }

    // MARK: - Chrome

    /// Shared cross-platform presentation decision. It becomes settled for a rendered non-empty cache without
    /// waiting for network validation, while cached empty remains covered until Proton confirms it.
    private var librarySettled: Bool {
        guard timelineModel.initialLibraryLoadState.hasSettled else { return false }
        guard !libraryRefresh.isBusy else { return false }
        if case .loading = timelineModel.state { return false }
        return true
    }

    /// Lifts the launch veil after visible thumbnails render.
    /// Empty and failed libraries lift it immediately because they have no thumbnails to render.
    private func evaluateVeilLift() {
        guard !model.libraryReady else {
            cancelVeilTasks()
            return
        }
        guard librarySettled else {
            cancelVeilTasks()
            return
        }
        if timelineModel.allItems.isEmpty {
            restoreInitialSidebarVisibilityIfNeeded()
            cancelVeilTasks()
            model.markLibraryReady()
            return
        }

        guard renderedLibraryRevision == timelineModel.gridSourceRevision else {
            veilSettleTask?.cancel()
            veilSettleTask = nil
            return
        }
        let revision = timelineModel.gridSourceRevision
        veilSettleTask?.cancel()
        veilSettleTask = Task { @MainActor in
            if !restoredInitialSidebarVisibility, !initiallyShowsSidebar {
                // Give the initially mounted `.all` column one committed titlebar frame before closing it.
                // Without this frame AppKit does not establish the toolbar's traffic-light exclusion region.
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
            }
            restoreInitialSidebarVisibilityIfNeeded()
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled,
                librarySettled,
                renderedLibraryRevision == revision,
                timelineModel.gridSourceRevision == revision
            else { return }
            veilSettleTask = nil
            PhotoDiagnostics.shared.emit(
                "FirstContent",
                [
                    "event": "veilLift", "phase": "coldStart", "revision": "\(revision)",
                ])
            model.markLibraryReady()
        }
    }

    private func cancelVeilTasks() {
        veilSettleTask?.cancel()
        veilSettleTask = nil
    }

    private var title: String {
        if selection == .map, let mapClusterPresentation {
            return mapClusterPresentation.title
        }
        switch selection {
        case .all: return L10n.string("library.title")
        case .tag(let t): return t.title
        case .album(_, let name): return name
        case .sharedAlbum(_, _, let name): return name
        case .trash: return String(localized: "sidebar.recently_deleted")
        case .map: return "Map"
        case .duplicates: return L10n.string("duplicates.title")
        }
    }

    private enum NavigationChromeState: Equatable {
        case route(String)
        case mapCluster(String)
        case viewer
    }

    private var navigationChromeState: NavigationChromeState {
        if viewerModel != nil {
            return .viewer
        }
        if selection == .map, let mapClusterPresentation {
            return .mapCluster(mapClusterPresentation.title)
        }
        return .route(title)
    }

    private var navigationChromeAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.28, extraBounce: 0)
    }

    private var backgroundLibraryActivityActive: Bool {
        OfflineLibraryManager.shared.isLibraryActivityActive
    }

    private func retryAfterConnectivityRestored() {
        if selection.hasTimeline {
            Task { await timelineModel.retry() }
        }
        Task { await loadAlbums() }
        model.refreshLibrarySources()
        OfflineLibraryManager.shared.restartLocationCrawl(items: timelineModel.allItems, metadata: backend)
    }

    private var gridFillOrder: GridFillOrder {
        selection == .all && committedSearchText.isEmpty && !activeRefinement.isActive
            ? .newestBottomTrailing : .topLeading
    }

    /// Filters apply to the Mediathek only; albums and smart collections keep their own contents.
    private var activeRefinement: TimelineRefinement {
        selection == .all ? refinement : .all
    }

    /// The grid shows the whole library without a search, a suggestion, or a filter.
    private var showsUnfilteredLibrary: Bool {
        selection == .all
            && committedSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && committedSuggestionMatches == nil
            && !activeRefinement.isActive
    }

    private var showsTemporalBrowser: Bool {
        selection == .all
            && committedSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !activeRefinement.isActive
            && temporalMode != .allPhotos
    }

    /// A filter shows single photos, so it switches Years and Months to All Photos; choosing Years or Months again
    /// removes the filter (see `temporalModeBinding`). The picker and the zoom controls always match the grid.
    private var refinementBinding: Binding<TimelineRefinement> {
        Binding {
            refinement
        } set: { next in
            if next.isActive, temporalMode != .allPhotos {
                temporalModeBinding.wrappedValue = .allPhotos
            }
            applyRefinement(next)
        }
    }

    /// Every filter change starts a new reading position, like a search: a filtered grid opens at its newest
    /// result, and removing the filter returns the full library to its newest photo at the bottom.
    private func applyRefinement(_ next: TimelineRefinement) {
        guard next != refinement else { return }
        refinement = next
        routeInitialScrollAnchor = nil
        routeScrollGeneration += 1
    }

    /// Filter menu of the Mediathek, with the same entries as on iPhone and iPad.
    private var libraryFilterMenu: some View {
        Menu {
            LibraryRefinementMenuContent(refinement: refinementBinding, favoritesAvailable: favoritesLoaded)
        } label: {
            Label(
                L10n.string("library.filter"),
                systemImage: refinement.isActive
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease"
            )
            .labelStyle(.iconOnly)
        }
        .help(refinement.localizedSummary)
        .accessibilityLabel(L10n.string("library.filter"))
        .accessibilityValue(refinement.localizedSummary)
    }

    private var temporalProjectionRequestID: String {
        "\(selection == .all ? "library" : "route")|\(temporalMode.rawValue)|\(timelineModel.contentRevision)"
    }

    private var temporalModeBinding: Binding<TimelineTemporalMode> {
        Binding {
            temporalMode
        } set: { mode in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                temporalMode = mode
                if mode != .months {
                    focusedTemporalYear = nil
                }
                if mode != .allPhotos {
                    applyRefinement(.all)
                }
            }
        }
    }

    private func rebuildTemporalProjection() async {
        let mode = temporalMode
        guard selection == .all, mode != .allPhotos else { return }
        temporalProjection = .loading(mode: mode)
        let sections = currentTimelineSections
        do {
            let projection = try await TimelineTemporalProjection.build(
                mode: mode,
                sections: sections,
                calendar: Calendar.current
            )
            guard !Task.isCancelled, temporalMode == mode, selection == .all else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                temporalProjection = projection
            }
        } catch is CancellationError {
            return
        } catch {
            temporalProjection = TimelineTemporalProjection(
                mode: mode,
                sections: [],
                calendar: Calendar.current
            )
        }
    }

    private func selectTemporalYear(_ year: TimelineTemporalYearGroup) {
        focusedTemporalYear = Calendar.current.component(.year, from: year.dateInterval.start)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            temporalMode = .months
        }
    }

    private func loadAlbums() async {
        albumLoadGeneration &+= 1
        let loadGeneration = albumLoadGeneration
        async let owned: Void = albumActions.refresh()
        async let shared: Void = albumActions.refreshSharedAlbums()
        await reloadFavorites()
        let (_, _) = await (owned, shared)
        guard !Task.isCancelled, loadGeneration == albumLoadGeneration else { return }
        if albumActions.loadErrorMessage == nil {
            albums = albumActions.albums
            uploadCoordinator.albums = albumActions.albums.map {
                UploadAlbumDestination(id: $0.id, title: $0.title)
            }
            albumCatalogFailed = false
        } else {
            // Preserve the last authoritative catalog during a transient/offline failure. Replacing
            // it with [] made real albums disappear and presented a false empty state until relaunch.
            albumCatalogFailed = true
        }
    }

    // MARK: - Upload

    private func performUploadUIAction(_ action: String, trigger: UploadUITrigger) {
        logUploadUI(action: action, trigger: trigger)
        switch action {
        case "uploadPhotos":
            presentUploadPhotos()
        case "uploadFolder":
            presentUploadFolder()
        case "showQueue":
            uploadCoordinator.isQueueVisible = true
        default:
            break
        }
    }

    private func presentUploadPhotos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie]
        panel.message = String(localized: "upload.choose_photos_message")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        uploadCoordinator.chooseDestination(files: panel.urls)
    }

    private func presentUploadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "upload.choose_folder_message")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        uploadCoordinator.chooseDestination(folder: folder)
    }

    private var refreshHost: MacLibraryRefreshController.Host {
        MacLibraryRefreshController.Host(
            timelineModel: timelineModel,
            model: model,
            loadAlbums: { await loadAlbums() },
            scrollToItem: { gridProxy.scrollToItem?($0) }
        )
    }

    private func scheduleUploadRefresh(_ event: UploadCompletedEvent) {
        libraryRefresh.scheduleUploadRefresh(event, host: refreshHost)
    }

    private func startLibraryChangeMonitor() async {
        // Coalesce with the timeline view's startup task, then seed monitoring with the token observed by the
        // shared cache validator. Starting earlier would consume a mutation during launch as a fresh baseline.
        await timelineModel.load()
        if timelineModel.initialLoadFailureReason == .scopeAccessLost {
            await model.recoverBackendAfterScopeAccessLoss()
            return
        }
        libraryRefresh.reconcileNewAssetThumbnails(
            timelineModel.takeInitialAuthoritativeAddedUIDs(), host: refreshHost)
        guard let provider = backend as? any LibraryChangeTokenProvider else { return }
        await libraryChangeMonitor.start(
            provider: provider,
            initialToken: timelineModel.initialLibraryChangeToken,
            onTerminal: { [model] _ in
                await model.recoverBackendAfterScopeAccessLoss()
            },
            onChange: { await libraryRefresh.performRemoteLibraryRefresh(host: refreshHost) }
        )
    }

    private func scheduleLibraryRefreshAfterBackupUpload() {
        libraryRefresh.scheduleBackupUploadRefresh(host: refreshHost)
    }

    private func refreshLibraryManually() {
        libraryRefresh.refreshManually(host: refreshHost)
    }

    private func logUploadUI(action: String, trigger: UploadUITrigger) {
        let line = "[UploadUI] action=\(action) trigger=\(trigger.rawValue)"
        DebugLog.log(line)
    }

    /// Honest Map empty state, mirroring the iOS states and the standard macOS library empty surface.
    @ViewBuilder private var mapEmptyState: some View {
        let index = OfflineLibraryManager.shared.locationIndex
        Group {
            if !networkMonitor.isOnline {
                OfflineContentUnavailableView()
            } else {
                switch index.scanProgress.phase {
                case .scanning:
                    ContentUnavailableView {
                        Label(L10n.string("map.scanning_title"), systemImage: "location.magnifyingglass")
                    } description: {
                        Text(
                            L10n.string(
                                "map.scanning_message \(index.scanProgress.scanned) \(index.scanProgress.total)"))
                    }
                case .failed:
                    ContentUnavailableView {
                        Label(L10n.string("map.scan_failed_title"), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(L10n.string("map.scan_failed_message"))
                    }
                case .completed:
                    ContentUnavailableView {
                        Label(L10n.string("map.empty_title"), systemImage: "mappin.slash")
                    } description: {
                        Text(L10n.string("map.no_places_found_message"))
                    }
                case .idle:
                    ContentUnavailableView {
                        Label(L10n.string("map.empty_title"), systemImage: "mappin.slash")
                    } description: {
                        Text(L10n.string("map.empty_message"))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProtonColor.backgroundNorm)
    }

    // MARK: - Favorites / trash

    /// Applies an optimistic favorite mutation for `selection`, rejecting a call that overlaps any
    /// mutation already in flight so a stale rollback cannot clobber a newer optimistic state.
    private func mutateFavorites(_ selection: Set<PhotoUID>) {
        // One direction for the whole selection; the backup applies it to pending photos after their upload.
        guard let target = FavoriteMutationPolicy.target(for: selection, current: displayedFavorites) else { return }
        let split = LocalPendingSplit(selection)
        if !split.local.isEmpty, let session = model.pendingGrid {
            Task { await session.setFavorite(split.local, favorite: target) }
        }
        guard let request = favoriteState.beginWrite(selection: Set(split.remote), target: target) else { return }
        Task {
            let failed = await FavoriteState.perform(request) { try await backend.setFavorites($0, $1) }
            favoriteState.finishWrite(request, failed: failed)
        }
    }

    /// Reads the server favorites, also after a trash or restore changed which photos can carry them. When the
    /// read fails, the `trashed` photos still lose their hearts.
    private func reloadFavorites(trashed: Set<PhotoUID> = []) async {
        let read = favoriteState.beginLoad()
        let loaded = try? await backend.favoriteUIDs()
        guard !Task.isCancelled else {
            favoriteState.cancelLoad(read)
            return
        }
        favoriteState.finishLoad(loaded, for: read)
        if loaded == nil { favoriteState.removeTrashed(trashed) }
    }

    /// Indicates whether every selected photo is a favorite.
    private var selectedAllFavorited: Bool {
        let favorites = displayedFavorites
        return !selectedUIDs.isEmpty && selectedUIDs.allSatisfy { favorites.contains($0) }
    }

    /// Sets the single selected photo as the current album's cover (direct REST), then refreshes the album list
    /// so the sidebar cover updates. Keeps the selection (non-destructive).
    private func setSelectedAsAlbumCover(albumID: String) {
        guard selectedUIDs.count == 1, let uid = selectedUIDs.first, !isSettingAlbumCover else { return }
        isSettingAlbumCover = true
        Task {
            defer { isSettingAlbumCover = false }
            do {
                try await facade.albums.setAlbumCover(albumID: albumID, photoUID: uid)
                await loadAlbums()
            } catch {
                albumCoverFailureMessage = String(
                    localized: "albums.cover_failed_message \(error.localizedDescription)")
            }
        }
    }

    private func deleteCurrentAlbum() {
        guard case .album(let albumID, _) = selection, !isDeletingAlbum else { return }
        isDeletingAlbum = true
        Task {
            defer { isDeletingAlbum = false }
            do {
                try await facade.albums.deleteAlbum(albumID: albumID)
                selectionMode = false
                selectedUIDs.removeAll()
                selection = .all
                await loadAlbums()
            } catch {
                albumDeleteFailureMessage = L10n.string("albums.delete_failed_message")
            }
        }
    }

    private func requestSelectedRemovalOrTrash() {
        if case .album = selection {
            confirmAlbumPhotoAction = true
        } else {
            trashSelected()
        }
    }

    private func removeSelectedFromCurrentAlbum() {
        guard case .album(let albumID, _) = selection,
            !selectedUIDs.isEmpty,
            !isTrashMutating
        else { return }
        let uids = Array(selectedUIDs)
        isTrashMutating = true
        Task {
            defer { isTrashMutating = false }
            do {
                try await facade.albums.removePhotos(uids, from: albumID)
                await timelineModel.select(selection)
                await loadAlbums()
                selectionMode = false
                selectedUIDs.removeAll()
            } catch {
                albumMembershipFailureMessage = L10n.string("albums.remove_photos_failed_message")
            }
        }
    }

    /// Builds the Duplicates route for this account, or leaves it when the account cannot merge duplicates.
    private func installDuplicates() async {
        duplicates = facade.exactDuplicates.map { finder in
            ExactDuplicatesModel(finder: finder) { trashed in await commitDuplicateTrash(trashed) }
        }
        guard let duplicates else {
            if selection == .duplicates { selection = .all }
            return
        }
        await duplicates.loadCountIfNeeded()
    }

    /// The finder already moved the copies to Recently Deleted; the library and its derived state stop showing them.
    private func commitDuplicateTrash(_ uids: [PhotoUID]) async {
        let trashed = Set(uids)
        await timelineModel.commitTrash(uids: trashed)
        await OfflineLibraryManager.shared.reconcileLocations(
            items: timelineModel.wholeLibraryItemsForViewer,
            metadata: backend,
            recrawlRestoredItems: false
        )
        await reloadFavorites(trashed: trashed)
    }

    private func trashPhotos(_ items: [PhotoItem], closeViewer: Bool) {
        guard !items.isEmpty, !isTrashMutating else { return }
        let local = items.filter(\.uid.isLocalPending).map(\.uid)
        let items = items.filter { !$0.uid.isLocalPending }
        let uids = items.map(\.uid)
        isTrashMutating = true
        Task {
            defer { isTrashMutating = false }
            if !local.isEmpty {
                guard await excludeFromBackup(local) else {
                    trashActionFailureMessage = String(localized: "alert.trash_failed_message")
                    return
                }
                if uids.isEmpty {
                    selectionMode = false
                    selectedUIDs = []
                    if closeViewer { closePhoto() }
                    return
                }
            }
            do {
                try await backend.trash(uids)
                await timelineModel.commitTrash(items)
                if mapClusterPresentation != nil { await mapClusterModel.commitTrash(items) }
                await OfflineLibraryManager.shared.reconcileLocations(
                    items: timelineModel.wholeLibraryItemsForViewer,
                    metadata: backend,
                    recrawlRestoredItems: false
                )
                await reloadFavorites(trashed: Set(uids))
                selectionMode = false
                selectedUIDs = []
                if closeViewer { closePhoto() }
            } catch {
                DebugLog.log("trash: FAILED n=\(uids.count) - \(error)")
                trashActionFailureMessage = String(localized: "alert.trash_failed_message")
            }
        }
    }

    private func restorePhotos(_ items: [PhotoItem], closeViewer: Bool = false) {
        guard !items.isEmpty, !isTrashMutating else { return }
        let local = items.filter(\.uid.isLocalPending).map(\.uid)
        let items = items.filter { !$0.uid.isLocalPending }
        let uids = items.map(\.uid)
        isTrashMutating = true
        Task {
            defer { isTrashMutating = false }
            if !local.isEmpty {
                // A photo deleted before upload goes back into the backup queue.
                guard await model.pendingGrid?.restore(local) == true else {
                    trashActionFailureMessage = String(localized: "alert.restore_failed_message")
                    return
                }
                if uids.isEmpty {
                    selectionMode = false
                    selectedUIDs = []
                    if closeViewer { closePhoto() }
                    return
                }
            }
            do {
                try await backend.restore(uids)
                model.pendingGrid?.photosRestored(uids)
                await timelineModel.commitRestore(items)
                await OfflineLibraryManager.shared.reconcileLocations(
                    items: timelineModel.wholeLibraryItemsForViewer,
                    metadata: backend,
                    recrawlRestoredItems: true
                )
                await reloadFavorites()
                selectionMode = false
                selectedUIDs = []
                if closeViewer { closePhoto() }
            } catch {
                DebugLog.log("restore: FAILED n=\(uids.count) - \(error)")
                trashActionFailureMessage = String(localized: "alert.restore_failed_message")
            }
        }
    }

    private func emptyTrash() {
        let uids = Set(timelineModel.allItems.map(\.uid))
        let pending = timelineModel.pendingTrash.items.map(\.uid)
        guard selection == .trash, !uids.isEmpty || !pending.isEmpty, !isEmptyingTrash else { return }
        isEmptyingTrash = true
        Task {
            defer { isEmptyingTrash = false }
            // Photos deleted before upload only leave the list; they stay excluded and stay in Apple Photos.
            if !pending.isEmpty, await model.pendingGrid?.removeFromTrashList(pending) != true {
                trashActionFailureMessage = L10n.string("trash.empty_failed_message")
                return
            }
            guard !uids.isEmpty else {
                selectedUIDs = []
                selectionMode = false
                return
            }
            do {
                try await backend.emptyTrash()
                timelineModel.commitEmptyTrash(uids)
                selectedUIDs = []
                selectionMode = false
            } catch {
                DebugLog.log("empty-trash: FAILED n=\(uids.count) - \(error)")
                await timelineModel.retry()
                trashActionFailureMessage = L10n.string("trash.empty_failed_message")
            }
        }
    }

    private var selectedItems: [PhotoItem] {
        if mapClusterPresentation != nil {
            return mapClusterModel.allItems.filter { selectedUIDs.contains($0.uid) }
        }
        // The retained Core snapshot answers the whole-library selection without scanning every item on each
        // action. Filtered routes keep their active-route ordering and membership because their items can include
        // trash or album-only identities that are not present in the whole-library snapshot.
        return timelineModel.gridItems(matching: selectedUIDs)
    }

    private func scheduleSearchCommit(_ value: String) {
        searchDebounceTask?.cancel()
        if semanticQuery == nil, let smartSearch = model.smartSearch {
            semanticQuery = MLSmartSearchQueryCoordinator(
                lifecycle: smartSearch.lifecycleActor,
                initialScope: searchScope
            )
        }
        clearPendingSuggestionText()
        switch searchDiscovery.commitDecision(
            for: value, content: searchDiscoveryContent, snapshot: model.smartSearch?.snapshot)
        {
        case .structured(let suggestion):
            commitSuggestion(suggestion, text: value)
        case .deferUntilRefresh:
            // The menu delivers a click as plain text. While the suggestions are not current, the text and the
            // grid stay as they are; `resolvePendingSuggestionText` decides after the refresh or the deadline.
            searchDebounceTask = nil
            pendingSuggestionText = value
            pendingSuggestionDeadlineTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                resolvePendingSuggestionText(force: true)
            }
        case .text:
            scheduleTextCommit(value)
        }
    }

    /// A chosen suggestion carries its exact result set. Commit it at once instead of debouncing and skip the
    /// semantic query for its display title.
    private func commitSuggestion(_ suggestion: TimelineSearchSuggestion, text value: String) {
        semanticQuery?.clear()
        if temporalMode != .allPhotos {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                temporalMode = .allPhotos
                focusedTemporalYear = nil
            }
        }
        routeInitialScrollAnchor = nil
        routeScrollGeneration += 1
        committedSuggestion = suggestion
        committedSearchText = value
        recordSearchHistory(suggestion.query)
        searchDebounceTask = nil
    }

    private func clearPendingSuggestionText() {
        pendingSuggestionDeadlineTask?.cancel()
        pendingSuggestionDeadlineTask = nil
        pendingSuggestionText = nil
    }

    /// Decides a deferred search text as soon as the published suggestions are final for the kind that owned
    /// it, or at the deadline (`force`): a suggestion that owns it is committed, any other text runs as an
    /// ordinary search. The text is never erased.
    private func resolvePendingSuggestionText(force: Bool = false) {
        guard let pending = pendingSuggestionText else { return }
        let decision = searchDiscovery.commitDecision(
            for: pending, content: searchDiscoveryContent, snapshot: model.smartSearch?.snapshot)
        if case .deferUntilRefresh = decision, !force { return }
        clearPendingSuggestionText()
        guard pending == searchText else { return }
        if case .structured(let suggestion) = decision {
            commitSuggestion(suggestion, text: pending)
        } else {
            scheduleTextCommit(pending)
        }
    }

    private func scheduleTextCommit(_ value: String) {
        searchDebounceTask?.cancel()
        semanticQuery?.update(query: value)
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            committedSuggestion = nil
            committedSearchText = ""
            // Clearing the search returns the full timeline to its newest item.
            routeInitialScrollAnchor = nil
            routeScrollGeneration += 1
            searchDebounceTask = nil
            return
        }
        if temporalMode != .allPhotos {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                temporalMode = .allPhotos
                focusedTemporalYear = nil
            }
        }
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            routeInitialScrollAnchor = nil
            routeScrollGeneration += 1
            committedSuggestion = nil
            committedSearchText = value
            searchDebounceTask = nil
        }
    }

    /// Search-suggestion refresh and rebinding, split out of `body`: inline, these handlers exceed the
    /// type-checker's time budget for the main modifier chain.
    private func searchDiscoveryLifecycle<Content: View>(_ view: Content) -> some View {
        view
            .onChange(of: searchDiscoveryContent) { _, _ in rebindCommittedSuggestion() }
            .onChange(of: model.smartSearch?.snapshot) { _, _ in rebindCommittedSuggestion() }
            .onChange(of: searchDiscovery.settledGeneration) { _, _ in
                rebindCommittedSuggestion()
                resolvePendingSuggestionText()
            }
            .onChange(of: ObjectIdentifier(searchDiscovery)) { _, _ in
                rebindCommittedSuggestion()
                resolvePendingSuggestionText()
            }
            // The first publish already decides a deferred title that no place or visual concept owned.
            .onChange(of: searchDiscovery.isCurrent(content: searchDiscoveryContent)) { _, _ in
                resolvePendingSuggestionText()
            }
            .onChange(of: searchText) { _, _ in updateSearchActivity() }
            .onDisappear {
                searchActivity?.end()
                searchActivity = nil
            }
            .task(id: searchDiscoveryTaskKey) {
                updateSearchActivity()
                model.searchSuggestions.update(
                    sections: currentTimelineSections,
                    timelineRevision: UInt64(truncatingIfNeeded: timelineModel.contentRevision),
                    favoriteUIDs: favorites,
                    coordinates: MapAndPlacesPolicy.suggestionCoordinates(
                        OfflineLibraryManager.shared.locationIndex.coordinates, enabled: mapAndPlacesEnabled),
                    smartSearch: model.smartSearch,
                    libraryIsSettled: librarySettled && !backgroundLibraryActivityActive,
                    cacheContentIsSettled: suggestionCacheContentReady,
                    coordinateRevision: OfflineLibraryManager.shared.locationIndex.revision
                )
            }
    }

    private func mapAndPlacesLifecycle<Content: View>(_ view: Content) -> some View {
        view.onChange(of: mapAndPlacesEnabled) { _, enabled in
            if enabled {
                viewerModel?.refreshPlaceNames()
                OfflineLibraryManager.shared.resumeMapAndPlaces(
                    items: timelineModel.wholeLibraryItemsForViewer, metadata: backend)
            } else {
                if selection == .map { selection = .all }
                OfflineLibraryManager.shared.pauseMapAndPlaces()
                Task { await NativePlaceNameResolver.shared.cancelPending() }
            }
        }
    }

    /// An open library viewer follows a photo that the backup replaced, such as an edit in Apple Photos. Other
    /// routes keep their collection: the trash must never turn a deleted photo into its live edit, and a
    /// replacement need not match a search or a filter.
    private func viewerFollowLifecycle<Content: View>(_ view: Content) -> some View {
        view.onChange(of: timelineModel.pendingPresentation.revision) { _, _ in
            guard viewerFollowsReplacements, selection == .all else { return }
            let presentation = timelineModel.pendingPresentation
            viewerModel?.followReplacements(presentation.replacements, in: presentation.snapshot)
        }
    }

    private func updateSearchActivity() {
        if !isSearchTextEmpty {
            if searchActivity?.isActive != true { searchActivity = LibraryRuntimeState.shared.beginActivity(.search) }
        } else {
            searchActivity?.end()
            searchActivity = nil
        }
    }

    private var searchDiscoveryTaskKey: String {
        SmartSearchDiscoveryScheduler.revisionKey(
            timelineRevision: UInt64(truncatingIfNeeded: timelineModel.contentRevision),
            favoriteUIDs: favorites, coordinateCount: OfflineLibraryManager.shared.locationIndex.coordinates.count,
            smartSearch: model.smartSearch, coordinateRevision: OfflineLibraryManager.shared.locationIndex.revision
        ) + "|librarySettled:\(librarySettled)|thumbnailWork:\(backgroundLibraryActivityActive)"
            + "|cacheContentSettled:\(suggestionCacheContentReady)"
            + "|mapAndPlaces:\(mapAndPlacesEnabled)"
    }

    private var suggestionCacheContentReady: Bool {
        favoritesLoaded && timelineModel.initialLibraryLoadState.knownCount != nil
    }

    private var isSearchTextEmpty: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchDiscoveryContent: SmartSearchContentIdentity {
        SmartSearchContentIdentity(
            timelineRevision: UInt64(truncatingIfNeeded: timelineModel.contentRevision),
            favoriteUIDs: favorites
        )
    }

    /// The committed suggestion while the committed text still shows its title.
    private var activeCommittedSuggestion: TimelineSearchSuggestion? {
        guard let committedSuggestion, committedSuggestion.owns(searchText: normalizedCommittedSearchText)
        else { return nil }
        return committedSuggestion
    }

    /// Resolved result set of the committed suggestion while the committed text still shows its title. While the
    /// suggestions are not current the committed set stays; the grid intersects it with the current items.
    private var committedSuggestionMatches: Set<PhotoUID>? {
        guard let active = activeCommittedSuggestion else { return nil }
        switch searchDiscovery.rebind(
            active, content: searchDiscoveryContent, snapshot: model.smartSearch?.snapshot)
        {
        case .keep(let current): return current.matchingUIDs
        case .pending: return active.matchingUIDs
        // Nothing matches until `rebindCommittedSuggestion` runs: it clears a dropped concept, or commits any other
        // dropped title as ordinary text.
        case .drop: return []
        }
    }

    /// Keeps the committed suggestion current after a library change, a search availability change or a
    /// finished refresh. A suggestion that can no longer work is left; its title must not fall back to a lexical
    /// or semantic search while visual search is unavailable: only then is the field cleared. Any other
    /// suggestion that no longer exists keeps its text, which the user may have typed, as an ordinary search.
    private func rebindCommittedSuggestion() {
        guard let active = activeCommittedSuggestion, active.owns(searchText: searchText) else { return }
        switch searchDiscovery.rebind(
            active, content: searchDiscoveryContent, snapshot: model.smartSearch?.snapshot)
        {
        case .keep(let current):
            guard current != active else { break }
            committedSuggestion = current
            if !current.owns(searchText: normalizedCommittedSearchText) {
                // The title changed: the field, the committed text and the stored suggestion must agree, or
                // the grid would lose the suggestion and run the old title as text.
                searchDebounceTask?.cancel()
                searchDebounceTask = nil
                clearPendingSuggestionText()
                committedSearchText = current.query
                searchText = current.query
            }
        case .pending:
            break
        case .drop:
            let visualAvailable = SmartSearchDiscoveryModel.visualConceptsAvailable(model.smartSearch?.snapshot)
            if active.kind == .concept, !visualAvailable {
                clearUnavailableSuggestionSearch()
            } else {
                committedSuggestion = nil
                scheduleTextCommit(searchText)
            }
        }
    }

    private func clearUnavailableSuggestionSearch() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        clearPendingSuggestionText()
        semanticQuery?.clear()
        committedSuggestion = nil
        committedSearchText = ""
        searchText = ""
    }

    private var currentTimelineSections: [TimelineSection] {
        guard case .loaded(let sections) = timelineModel.state else { return [] }
        return sections
    }

    private func recordSearchHistory(_ rawQuery: String) {
        var next = searchHistory
        next.record(rawQuery)
        guard next != searchHistory else { return }
        searchHistory = next
    }

    private func clearSearchHistory() {
        searchHistory.clear()
    }

    private var normalizedCommittedSearchText: String {
        committedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func trashSelected() {
        let items = selectedItems
        requestTrash(items, closeViewer: false)
    }

    private func restoreSelected() {
        let items = selectedItems
        restorePhotos(items)
    }

    private func requestTrash(_ items: [PhotoItem], closeViewer: Bool) {
        guard !items.isEmpty else { return }
        pendingTrashItems = items
        closeViewerAfterTrash = closeViewer
        confirmTrash = true
    }

    private var trashConfirmationTitle: String {
        pendingTrashItems.count == 1
            ? String(localized: "alert.trash_confirmation_title_one")
            : String(localized: "alert.trash_confirmation_title_other \(pendingTrashItems.count)")
    }

    private var trashConfirmationMessage: String {
        pendingTrashItems.count == 1
            ? String(localized: "alert.trash_confirmation_message_one")
            : String(localized: "alert.trash_confirmation_message_other")
    }

    /// Applies detail controls at split-view scope. NavigationSplitView owns its default sidebar control so macOS
    /// places it in the sidebar's title-bar region, matching Apple Photos.
    private func synchronizedToolbar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .toolbar { toolbarContent }
            // Keep one logical native toolbar group while its contents change. macOS can then morph the
            // system-supplied Liquid Glass shape instead of tearing down one capsule and mounting another.
            .animation(navigationChromeAnimation, value: navigationChromeState)
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .contentTransition(.interpolate)
                .accessibilityAddTraits(.isHeader)
                // Refresh the native title's measurement and accessibility label when its text changes.
                .id(title)
        }
        .hidden(viewerModel != nil)
        .sharedBackgroundVisibility(.visible)

        ToolbarItem(placement: .navigation) {
            Button {
                if viewerModel != nil {
                    closePhoto()
                } else {
                    closeMapCluster()
                }
            } label: {
                Label("toolbar.back", systemImage: "chevron.left")
            }
            .help("toolbar.back_to_library")
        }
        .hidden(viewerModel == nil && !(selection == .map && mapClusterPresentation != nil))
        .sharedBackgroundVisibility(.visible)

        if let viewerModel {
            // Apple-Photos centered two-line metadata in a pill: location/POI (or date) over the
            // secondary line. No vertical padding: the toolbar gives the pill the height of the other
            // glass groups and centers the text, so the pill never grows below them.
            ToolbarItem(placement: .principal) {
                let t = viewerTitle(viewerModel)
                VStack(spacing: 0) {
                    Text(t.line1)
                        .font(.system(size: 13, weight: .semibold))
                        .opacity(t.reservesLocationLine ? 0 : 1)
                        .lineLimit(1)
                    Text(t.line2)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.center)
                .fixedSize()
                .padding(.horizontal, 16)
                // The system toolbar supplies the single glass background for the principal item.
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewerModel.toggleInfo()
                } label: {
                    Label("toolbar.info", systemImage: viewerModel.showInfo ? "info.circle.fill" : "info.circle")
                        .labelStyle(.iconOnly)
                }
                .help("toolbar.info")
                .accessibilityLabel("toolbar.info")

                if isExporting {
                    exportProgressIndicator  // the download icon is replaced by the progress ring while exporting
                    exportCancelButton
                } else {
                    let downloadTitle =
                        viewerModel.hasBurstFilmstrip ? "toolbar.download_burst_zip" : "toolbar.download_original"
                    Button {
                        downloadViewerSelection(viewerModel)
                    } label: {
                        Label(LocalizedStringKey(downloadTitle), systemImage: "square.and.arrow.down")
                            .labelStyle(.iconOnly)
                    }
                    .help(LocalizedStringKey(downloadTitle))
                    .accessibilityLabel(LocalizedStringKey(downloadTitle))
                    .disabled(!viewerModel.canDownloadCurrentSelection)
                }

                if viewerMutationAction == .saveToLibrary {
                    saveToLibraryButton(uids: [viewerModel.current.uid])
                } else {
                    Button {
                        mutateFavorites([viewerModel.current.uid])
                    } label: {
                        Label(
                            favorites.contains(viewerModel.current.uid)
                                ? "toolbar.remove_favorite" : "toolbar.favorite",
                            systemImage: favorites.contains(viewerModel.current.uid) ? "heart.fill" : "heart"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .help(
                        favorites.contains(viewerModel.current.uid) ? "toolbar.remove_favorite" : "toolbar.favorite"
                    )
                    .accessibilityLabel(
                        favorites.contains(viewerModel.current.uid) ? "toolbar.remove_favorite" : "toolbar.favorite")
                }

                if viewerMutationAction == .moveToTrash {
                    // The grid's album button for the open photo. The grid toolbar is hidden while the viewer is
                    // open, so both share one popover state.
                    AlbumAddButton(
                        coordinator: albumActions,
                        photoUIDs: [viewerModel.current.uid],
                        isPresented: $showAlbumDestination,
                        onAlbumsChanged: { Task { await loadAlbums() } }
                    )
                    .labelStyle(.iconOnly)
                    // A photo that is moving to the Trash cannot join an album.
                    .disabled(isTrashMutating)
                }

                Menu {
                    if viewerModel.hasLiveText {
                        Button {
                            viewerModel.liveTextHighlighted.toggle()
                        } label: {
                            Label(
                                viewerModel.liveTextHighlighted
                                    ? L10n.string("viewer.live_text_hide") : L10n.string("viewer.live_text_show"),
                                systemImage: "text.viewfinder"
                            )
                        }
                        Divider()
                    }
                    switch viewerMutationAction {
                    case .restore:
                        Button {
                            performViewerMutation(viewerModel.current)
                        } label: {
                            Label("toolbar.restore_from_trash", systemImage: "arrow.uturn.backward")
                        }
                    case .saveToLibrary:
                        Button {
                            performViewerMutation(viewerModel.current)
                        } label: {
                            Label(
                                L10n.string("library.save_to_library"),
                                systemImage: PhotoContextMenuAction.saveToLibrary.systemImage)
                        }
                        .disabled(isSavingToLibrary)
                    case .moveToTrash:
                        Button(role: .destructive) {
                            performViewerMutation(viewerModel.current)
                        } label: {
                            Label("toolbar.move_to_trash", systemImage: "trash")
                        }
                    }
                } label: {
                    Label(L10n.string("albums.more_actions"), systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .help(L10n.string("albums.more_actions"))
                .accessibilityLabel(L10n.string("albums.more_actions"))
                .disabled(isTrashMutating)
            }
        } else {
            // Click / ⌘-click / ⇧-click / drag-marquee select directly, while an album's native menu can
            // also make selection mode explicit. The toolbar is stable - the download (or restore) + trash actions
            // are always present and just enable when something is selected. The scene's hidden title-bar style
            // requires the route title to occupy the native navigation placement explicitly; a non-control Text
            // remains plain while reserving the expected leading toolbar width. The activity/offline indicator is
            // an unframed content overlay, not a toolbar item.
            // Apple toolbars have semantic regions: library commands use primaryAction, common view controls
            // occupy the principal center, and selection actions use secondaryAction alongside the system-owned
            // search field. Fixed spacers only separate independent primary commands.
            if case .album = selection {
                ToolbarItem(placement: .primaryAction) { albumActionsToolbarMenu }
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            if selection == .duplicates, let duplicates {
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.string("duplicates.merge_all")) { confirmsDuplicateMergeAll = true }
                        .disabled(!duplicates.canMerge)
                        .accessibilityIdentifier("duplicates.mergeAll")
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) { uploadToolbarMenu }
            librarySelectionAndViewToolbarContent
        }

        if viewerModel == nil,
            let mapClusterPresentation,
            mapClusterPresentation.pager.pageCount > 1
        {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    loadMapClusterPage(mapClusterPageIndex - 1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(mapClusterPageIndex == 0)
                Text("\(mapClusterPageIndex + 1)/\(mapClusterPresentation.pager.pageCount)")
                    .monospacedDigit()
                Button {
                    loadMapClusterPage(mapClusterPageIndex + 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(mapClusterPageIndex + 1 >= mapClusterPresentation.pager.pageCount)
            }
        }
    }

    @ToolbarContentBuilder private var librarySelectionAndViewToolbarContent: some ToolbarContent {
        if selection != .trash, !selection.isReadOnly {
            ToolbarItemGroup(placement: .secondaryAction) {
                downloadActionItem
                AlbumAddButton(
                    coordinator: albumActions,
                    photoUIDs: Array(selectedUIDs),
                    isPresented: $showAlbumDestination,
                    onAlbumsChanged: { Task { await loadAlbums() } },
                    onCompleted: { _ in endSelection() }
                )
                .labelStyle(.iconOnly)
                Button {
                    requestSelectedRemovalOrTrash()
                } label: {
                    Label("toolbar.move_selected_to_trash", systemImage: "trash").labelStyle(.iconOnly)
                }
                // Command-Delete is the system-wide delete key equivalent. It opens the same confirmation
                // as the button, so no selection leaves the library without the user confirming it.
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selectedUIDs.isEmpty || isTrashMutating)
                .help("toolbar.move_to_trash")
                .accessibilityLabel("toolbar.move_selected_to_trash")
                Button {
                    mutateFavorites(selectedUIDs)
                } label: {
                    Label(
                        selectedAllFavorited ? "toolbar.remove_favorite" : "toolbar.favorite_selected",
                        systemImage: selectedAllFavorited ? "heart.fill" : "heart"
                    )
                    .labelStyle(.iconOnly)
                }
                .disabled(selectedUIDs.isEmpty)
                .help(selectedAllFavorited ? "toolbar.remove_favorite" : "toolbar.favorite_selected")
                .accessibilityLabel(selectedAllFavorited ? "toolbar.remove_favorite" : "toolbar.favorite_selected")
                if case .album(let albumID, _) = selection {
                    Button {
                        setSelectedAsAlbumCover(albumID: albumID)
                    } label: {
                        Label("toolbar.set_album_cover", systemImage: "rectangle.badge.checkmark").labelStyle(.iconOnly)
                    }
                    .disabled(selectedUIDs.count != 1 || isSettingAlbumCover)
                    .help("toolbar.set_album_cover")
                    .accessibilityLabel("toolbar.set_album_cover")
                }
            }
        } else if selection.isReadOnly {
            // Shared albums live on another account's volume: download and Save to Library only.
            ToolbarItemGroup(placement: .secondaryAction) {
                downloadActionItem
                saveToLibraryButton(uids: selectedUIDs)
            }
        } else {
            ToolbarItemGroup(placement: .secondaryAction) {
                downloadActionItem
                Button {
                    confirmEmptyTrash = true
                } label: {
                    Label(L10n.string("trash.empty_button"), systemImage: "trash.slash").labelStyle(.iconOnly)
                }
                .disabled(timelineModel.gridItems.isEmpty || isEmptyingTrash || isTrashMutating)
                .help(L10n.string("trash.empty_button"))
                .accessibilityLabel(L10n.string("trash.empty_button"))
            }
        }
        ToolbarItemGroup(placement: .principal) {
            Picker("", selection: temporalModeBinding) {
                Text(L10n.string("library.view_years")).tag(TimelineTemporalMode.years)
                Text(L10n.string("library.view_months")).tag(TimelineTemporalMode.months)
                Text(L10n.string("library.view_all_photos")).tag(TimelineTemporalMode.allPhotos)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 260)
            .opacity(selection == .all ? 1 : 0)
            .allowsHitTesting(selection == .all)
            .accessibilityHidden(selection != .all)
        }
        // Its own item, so the pair renders as one grouped capsule like Apple Photos.
        ToolbarItem(placement: .principal) {
            ControlGroup {
                Button {
                    activeGridProxy.zoomOut?()
                } label: {
                    Label("toolbar.smaller_thumbnails", systemImage: "minus").labelStyle(.iconOnly)
                }
                .help("toolbar.smaller_thumbnails")
                .disabled(level >= 5 || temporalMode != .allPhotos)
                .accessibilityLabel("toolbar.smaller_thumbnails")
                Button {
                    activeGridProxy.zoomIn?()
                } label: {
                    Label("toolbar.larger_thumbnails", systemImage: "plus").labelStyle(.iconOnly)
                }
                .help("toolbar.larger_thumbnails")
                .disabled(level <= 0 || temporalMode != .allPhotos)
                .accessibilityLabel("toolbar.larger_thumbnails")
            }
        }
        ToolbarItem(placement: .principal) { aspectSquareToggleButton }
        if selection == .all {
            ToolbarItem(placement: .principal) { libraryFilterMenu }
        }
    }

    /// Toggles thumbnail content fitting without changing grid geometry.
    /// Dense overview levels always use square cropping.
    private var aspectSquareToggleButton: some View {
        Button {
            gridContentMode = AspectSquareToggleModel.toggled(gridContentMode)
            activeGridProxy.setContentMode?(gridContentMode)
        } label: {
            Image(nsImage: AspectSquareToggleModel.image(for: gridContentMode))
        }
        .help(AspectSquareToggleModel.accessibilityLabel(for: gridContentMode))
        .accessibilityLabel(AspectSquareToggleModel.accessibilityLabel(for: gridContentMode))
        .disabled(level >= 4 || temporalMode != .allPhotos)  // overview and curated modes are square-only
    }

    private var viewerMutationAction: ViewerMutationAction {
        ViewerMutationPolicy.action(for: ViewerCollectionContext(filter: selection))
    }

    private func performViewerMutation(_ item: PhotoItem) {
        switch viewerMutationAction {
        case .moveToTrash:
            requestTrash([item], closeViewer: true)
        case .restore:
            restorePhotos([item], closeViewer: true)
        case .saveToLibrary:
            saveToLibrary([item.uid])
        }
    }

    /// Copies photos from a shared album into the own library. The shared originals stay unchanged.
    private func saveToLibraryButton(uids: Set<PhotoUID>) -> some View {
        Button {
            saveToLibrary(Array(uids))
        } label: {
            if isSavingToLibrary {
                ProgressView().controlSize(.small)
            } else {
                Label(
                    L10n.string("library.save_to_library"),
                    systemImage: PhotoContextMenuAction.saveToLibrary.systemImage
                )
                .labelStyle(.iconOnly)
            }
        }
        .disabled(uids.isEmpty || isSavingToLibrary)
        .help(L10n.string("library.save_to_library"))
        .accessibilityLabel(L10n.string("library.save_to_library"))
    }

    /// Reuses the view's single title-and-message alert: the body modifier chain has no room for another alert.
    private func saveToLibrary(_ uids: [PhotoUID]) {
        guard !uids.isEmpty, !isSavingToLibrary else { return }
        isSavingToLibrary = true
        Task { @MainActor in
            defer { isSavingToLibrary = false }
            do {
                let result = try await backend.saveToLibrary(uids)
                exportFailureTitle = L10n.string("library.save_to_library")
                exportFailureMessage = result.message
                if !result.saved.isEmpty { refreshLibraryManually() }
            } catch {
                DebugLog.log("save to library failed: \(error)")
                exportFailureTitle = L10n.string("library.save_to_library_failed")
                exportFailureMessage = error.localizedDescription
            }
        }
    }

    /// Center-title metadata for the viewer top bar. `placeName` is the reverse-geocoded POI/location
    /// headline (nil until resolved or when the photo has no GPS); the filename fallback is best-effort
    /// (only populated while the Info panel is open).
    private func viewerTitle(_ vm: PhotoViewerModel) -> ViewerTitle {
        ViewerTitleFormatter.make(
            captureDate: vm.current.captureTime,
            index: vm.index,
            total: vm.items.count,
            locationName: mapAndPlacesEnabled ? vm.placeName : nil,
            locationIsResolving: mapAndPlacesEnabled && vm.isPlaceNameResolving,
            filename: vm.metadata?.filename
        )
    }

    // MARK: - Sidebar

    private func toggleSidebar() {
        withAnimation(Self.sidebarAnimation) {
            sidebarOpen.toggle()
            columnVisibility = sidebarOpen ? .all : .detailOnly  // drive the native split view
        }
        SidebarPersistence.saveVisible(sidebarOpen)
    }

    private func restoreInitialSidebarVisibilityIfNeeded() {
        guard !restoredInitialSidebarVisibility else { return }
        restoredInitialSidebarVisibility = true
        guard !initiallyShowsSidebar else { return }

        // This is called only after the first content frame or a settled empty/error state. By then AppKit has
        // committed the `.all` mount. Drive the same native transition as a real sidebar toggle so AppKit also
        // establishes its titlebar navigation region; the launch cover and its 250 ms settle barrier hide it.
        withAnimation(Self.sidebarAnimation) {
            sidebarOpen = false
            columnVisibility = .detailOnly
        }
    }

    // MARK: - Download / export

    private struct ExportRequest {
        let items: [PhotoItem]
        let zipSuggestedName: String?
    }

    private func downloadSelected() {
        let items = selectedItems
        guard !items.isEmpty, !isExporting else { return }
        Task { @MainActor in
            let request = await makeExportRequest(
                for: items, preferredSeriesNameSource: items.count == 1 ? items[0] : nil)
            startOrConfirmExport(request)
        }
    }

    private func downloadViewerSelection(_ viewerModel: PhotoViewerModel) {
        let items = viewerModel.exportItemsForDownload
        guard !items.isEmpty, !isExporting else { return }
        Task { @MainActor in
            let request = await makeExportRequest(for: items, preferredSeriesNameSource: viewerModel.baseCurrent)
            startOrConfirmExport(request)
        }
    }

    private func startOrConfirmExport(_ request: ExportRequest) {
        guard !request.items.isEmpty, !isExporting else { return }
        if request.items.count > largeExportThreshold {
            pendingExportItems = request.items
            pendingExportZipName = request.zipSuggestedName
            confirmLargeExport = true  // confirm large multi-downloads before zipping
        } else {
            startExport(request.items, zipSuggestedName: request.zipSuggestedName)
        }
    }

    /// Expands a selected Proton burst/series title photo into all known members before export. This keeps the
    /// grid toolbar and viewer toolbar on the same E2EE-safe export path; only the item list and suggested ZIP
    /// filename are prepared here.
    @MainActor private func makeExportRequest(
        for sourceItems: [PhotoItem],
        preferredSeriesNameSource: PhotoItem?
    ) async -> ExportRequest {
        var expanded: [PhotoItem] = []
        var seen = Set<PhotoUID>()
        var expandedSingleSeries = false

        func appendUnique(_ item: PhotoItem) {
            guard seen.insert(item.uid).inserted else { return }
            expanded.append(item)
        }

        let memberIDSet = Set(
            (preferredSeriesNameSource?.burstMemberIDs ?? []).map {
                PhotoUID(volumeID: preferredSeriesNameSource?.uid.volumeID ?? "", nodeID: $0)
            })
        let sourceUIDSet = Set(sourceItems.map(\.uid))
        let alreadyExpandedPreferredSeries =
            sourceItems.count > 1
            && preferredSeriesNameSource?.isBurstCandidate == true
            && !memberIDSet.isEmpty
            && sourceUIDSet.isSubset(of: memberIDSet)

        if alreadyExpandedPreferredSeries {
            sourceItems.forEach(appendUnique)
            expandedSingleSeries = true
        } else {
            for item in sourceItems {
                if item.isBurstCandidate,
                    let group = try? await backend.burstGroup(containing: item.uid),
                    group.count > 1
                {
                    group.forEach(appendUnique)
                    expandedSingleSeries = true
                } else {
                    appendUnique(item)
                }
            }
        }

        let zipName: String?
        if expandedSingleSeries, expanded.count > 1, let source = preferredSeriesNameSource ?? sourceItems.first {
            zipName = await suggestedSeriesZipName(for: source)
        } else {
            zipName = nil
        }
        return ExportRequest(items: expanded, zipSuggestedName: zipName)
    }

    @MainActor private func suggestedSeriesZipName(for item: PhotoItem) async -> String {
        let meta = try? await backend.metadata(for: item.uid)
        let fallback = Self.defaultName(item, ext: Self.defaultExtension(item, metadata: meta))
        let filename = meta?.filename?.isEmpty == false ? meta?.filename : fallback
        let stem = URL(fileURLWithPath: filename ?? fallback).deletingPathExtension().lastPathComponent
        let safeStem = stem.isEmpty ? "EncryptedMemories" : stem
        return "\(safeStem)-\(String(localized: "export.series_zip_suffix")).zip"
    }

    /// Single entry point for launching an export, so the toolbar ring's menu has one task to cancel.
    private func startExport(_ items: [PhotoItem], zipSuggestedName: String? = nil) {
        exportTask?.cancel()
        // A Live Photo leaves as its still and its motion video, so it exports as an archive of both.
        let files = OutboundMedia.files(for: items).map(\.item)
        exportTask = Task { await performExport(files, zipSuggestedName: zipSuggestedName) }
    }

    /// Cancels the running download (from the toolbar ring's menu). `performExport` discards any partial ZIP.
    private func cancelExport() { exportTask?.cancel() }

    /// Coordinates destination selection and UI state; transfer and file work remain off the main actor.
    @MainActor private func performExport(_ items: [PhotoItem], zipSuggestedName: String?) async {
        // Pending photos export from Apple Photos, every other photo from Proton.
        let backend = self.media
        // Captures self only to push 0…1 onto the @State ring; the closure itself runs on the main actor.
        let onProgress: @Sendable (Double) -> Void = { p in Task { @MainActor in self.exportFraction = p } }

        // Show progress only after the user has selected a destination.
        let single = items.count == 1
        let dest: URL
        if single {
            let item = items[0]
            let meta = try? await backend.metadata(for: item.uid)
            let original = meta?.filename ?? Self.defaultName(item, ext: Self.defaultExtension(item, metadata: meta))
            // Without location, a RAW photo leaves as a JPEG, so the save panel suggests that name.
            let name =
                PrivacyExportPolicy.isEnabled()
                ? LocationSanitizedCopy.outputFilename(forOriginalName: original) : original
            guard let chosen = chooseSingleDestination(suggestedName: name) else { return }
            dest = chosen
        } else {
            // Stream multi-item exports into one archive, staging one SDK download at a time.
            guard let chosen = chooseZipDestination(suggestedName: zipSuggestedName) else { return }
            dest = chosen
        }

        // Keep the Powerbox grant active for the complete asynchronous export.
        let hasScopedAccess = dest.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                dest.stopAccessingSecurityScopedResource()
            }
        }

        // The transfer starts after destination selection, so progress can now become visible.
        let activity = LibraryRuntimeState.shared.beginActivity(.userTransfer)
        defer { activity.end() }
        exportFraction = 0
        withAnimation(.smooth(duration: 0.35)) { isExporting = true }
        defer {
            withAnimation(.smooth(duration: 0.3)) { isExporting = false }
            exportTask = nil
        }

        do {
            if single {
                try await OriginalExportWriter.writeSingle(
                    item: items[0], to: dest, provider: backend, onProgress: onProgress)
            } else {
                try await OriginalExportWriter.writeArchive(
                    items: items, to: dest, provider: backend, onProgress: onProgress)
            }
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch is CancellationError {
            // User cancelled from the ring popover; the worker's `defer` already discarded any partial output.
        } catch OriginalExportWriter.Failure.lowDisk {
            exportFailureTitle = String(localized: "export.low_disk_title")
            exportFailureMessage = String(localized: "export.low_disk_message")
        } catch {
            DebugLog.log("export failed: \(error)")
            exportFailureTitle = String(localized: "export.failed_title")
            exportFailureMessage = String(localized: "export.failed_message \(error.localizedDescription)")
        }
    }

    private func chooseZipDestination(suggestedName: String? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName ?? "Encrypted Memories Export.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func chooseSingleDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    nonisolated private static func defaultName(_ item: PhotoItem, ext: String) -> String {
        let e = ext.isEmpty ? "jpg" : ext
        return "\(item.uid.nodeID.prefix(8)).\(e)"
    }

    nonisolated private static func defaultExtension(_ item: PhotoItem, metadata: PhotoMetadata?) -> String {
        // Resolve the extension from the filename, MIME type, or timeline media type.
        // No response header exists before the download starts.
        OriginalFileNaming.resolvedExtension(
            filename: metadata?.filename, mimeType: metadata?.mimeType, header: nil,
            fallbackMediaType: item.mediaType, isVideo: item.isVideo
        )
    }
}

private extension View {
    /// Applies a view-building function; keeps long modifier chains within the type-checker's budget.
    func applying<Transformed: View>(_ transform: (Self) -> Transformed) -> Transformed {
        transform(self)
    }
}
