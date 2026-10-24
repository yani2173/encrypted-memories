import AVFoundation
import AVKit
import AlbumCore
import AlbumsFeature
import Combine
import DesignSystemCore
import MapUIKitAdapter
import MediaByteCache
import MediaCacheUIKitAdapter
import MediaFeedCore
import MediaLocationCore
import PhotoViewerCore
import PhotoViewerUIKitAdapter
import PhotosCore
import SwiftUI
import TimelineCore
import UIKit
import UploadCore
import VisionKit

/// Native full-screen photo/video viewer. Paging + chrome live here (pure presentation); the media decoding,
/// titles, video-playback and pinch-to-close semantics come from shared `PhotoViewerCore` and the shared
/// backend - no viewer business logic is reimplemented per platform.
struct MobilePhotoViewer: View {
    @AppStorage(AppSettingsKey.mapAndPlacesEnabled) private var mapAndPlacesEnabled =
        AppSettingsDefault.mapAndPlacesEnabled
    @State private var items: [PhotoItem]
    /// Changes whenever `items` changes, so the pager compares one number instead of the whole collection.
    @State private var itemsRevision = 0
    let startIndex: Int
    let context: ViewerCollectionContext
    let libraryModel: MobileLibraryModel
    let viewerRouter: MobileViewerRouter
    /// True for a library viewer: it follows a photo that the backup replaced, such as an edit in Apple Photos.
    let followsLibraryReplacements: Bool
    /// A group of duplicates: the bottom bar keeps a copy and merges the group instead of the library actions.
    let duplicateGroup: MobileDuplicateViewerGroup?
    @State private var pageIndex: ViewerPageIndex

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var index: Int
    @State private var chromeVisible = true
    @State private var burstSelection = BurstSelectionModel()
    @State private var editedOriginal = EditedPhotoOriginalState()
    @State private var editedOriginalLookup = EditedPhotoOriginalLookup()
    @State private var selection = MobileGridSelectionController()
    @State private var isRestoring = false
    @State private var showRestoreError = false
    @State private var showFavoriteError = false
    @State private var isSavingToLibrary = false
    @State private var saveToLibraryMessage: String?
    /// The page whose displayed still has recognized text, and whether that text is highlighted.
    @State private var liveTextUID: PhotoUID?
    @State private var liveTextHighlighted = false
    @State private var favoriteTask: Task<Void, Never>?
    @State private var favoriteRequestGeneration: UInt64 = 0
    @State private var restoreTask: Task<Void, Never>?
    @State private var restoreRequestGeneration: UInt64 = 0
    @State private var showInfo = false
    @State private var metadataLoadState: PhotoMetadataLoadState = .idle
    @State private var metadataRequestGeneration: UInt64 = 0
    @State private var showAlbumPicker = false
    @State private var albumTitles: [String] = []
    @State private var isLoadingAlbumMemberships = false
    @State private var albumMembershipsLoadFailed = false
    /// The title/info metadata request already resolves the authoritative link MIME type. Feed that
    /// result into the page router too, so a video mislabeled by incomplete timeline metadata switches to
    /// native playback instead of leaving the image page spinning forever.
    @State private var resolvedMediaKinds: [PhotoUID: MediaKind] = [:]
    @State private var titleMetadataState: ViewerTitleMetadataState = .resolving
    @State private var titleMetadataCoordinator: ViewerTitleMetadataCoordinator
    /// Ties the loaded series to its library page so an index change can never show the previous page's series.
    @State private var burstBaseUID: PhotoUID?
    /// The presented "Select Favorites" mode of the current series.
    @State private var seriesModel: MobileSeriesFavoritesModel?
    /// Bounded, shared image loader for the pages (thumbnail to screen-bounded preview, off-main and cached).
    /// the shared `PhotoViewerUIKitAdapter` store, wired to the feed's RAM tier via a closure so the
    /// adapter never depends on a concrete feed type.
    @State private var imageStore: UIKitViewerImageStore
    /// Read access to the cached thumbnail of the shown Duplicates copy, which can lie outside the library.
    @State private var visibleThumbnail: VisibleThumbnailSession?

    init(
        items: [PhotoItem],
        startIndex: Int,
        context: ViewerCollectionContext,
        libraryModel: MobileLibraryModel,
        viewerRouter: MobileViewerRouter,
        showsInfoInitially: Bool = false,
        followsLibraryReplacements: Bool = false,
        duplicateGroup: MobileDuplicateViewerGroup? = nil
    ) {
        _showInfo = State(initialValue: showsInfoInitially)
        _items = State(initialValue: items)
        self.startIndex = startIndex
        self.context = context
        self.libraryModel = libraryModel
        self.viewerRouter = viewerRouter
        self.followsLibraryReplacements = followsLibraryReplacements
        self.duplicateGroup = duplicateGroup
        _pageIndex = State(initialValue: ViewerPageIndex(orderedUIDs: items.map(\.uid)))
        _index = State(initialValue: min(max(startIndex, 0), max(items.count - 1, 0)))
        _titleMetadataCoordinator = State(
            initialValue: ViewerTitleMetadataCoordinator(
                metadataProvider: libraryModel.backend == nil ? nil : libraryModel.viewerMedia,
                placeNameResolver: NativePlaceNameResolver.shared
            ))
        let feed = libraryModel.thumbnailFeed
        let visibleThumbnail = duplicateGroup == nil ? nil : feed.map { VisibleThumbnailSession(feed: $0.feedCore) }
        if items.indices.contains(startIndex) { visibleThumbnail?.select(items[startIndex].uid) }
        _visibleThumbnail = State(initialValue: visibleThumbnail)
        // Seed/reuse the E2EE originals cache via the shared helper, injected as a closure so the viewer
        // adapter stays decoupled from the cache layer. When the viewer decrypts an original (a no-preview
        // item), it lands in the encrypted cache and later opens / shares reuse it before the network.
        // Pending photos that are not in Proton yet open from Apple Photos; everything else from Proton.
        let media = libraryModel.viewerMedia
        let originalFetch: (@Sendable (PhotoUID) async throws -> Data)?
        if let backend = libraryModel.backend, let originals = libraryModel.originalsCache {
            let provider = EncryptedOriginalProvider(
                media: backend, cache: originals,
                policy: .persisting(capBytes: libraryModel.originalsCacheCapBytes)
            )
            originalFetch = { uid in
                if uid.isLocalPending { return try await media.originalData(for: uid) { _ in } }
                return try await provider.originalData(for: uid)
            }
        } else {
            originalFetch = nil
        }
        _imageStore = State(
            initialValue: UIKitViewerImageStore(
                thumbnailProvider: { feed?.memoryImage(for: $0) },
                cachedThumbnailProvider: { uid in
                    if let visibleThumbnail { return await visibleThumbnail.cachedImage(for: uid) }
                    return await feed?.cachedImage(for: uid)
                },
                media: media,
                originalDataOverride: originalFetch))
    }

    var body: some View {
        // Native bars inside the cover: the system owns the bar axis, edge, overflow and Liquid Glass, so the
        // viewer receives the iPhone Duo vertical layout and the iPad top-bar placement without app geometry.
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                // UIKit pager (UIPageViewController) instead of SwiftUI's page TabView, because rotation
                // must preserve the current page during the size transition.
                // The SwiftUI pager keeps its width-bound content offset and page size through a device rotation,
                // so the photo rotated displaced in a corner and snapped to centre only afterwards (a rebuild via
                // `.id` was a hard cut instead). UIPageViewController participates in the size transition and keeps
                // the current page centred through the whole rotation - the Photos-app behavior.
                MobileViewerPager(
                    count: items.count, revision: itemsRevision, id: { items[$0].uid }, index: $index
                ) { i, isCurrent in
                    // The page of an edited photo shows its original while the person asks for it.
                    let item = editedOriginal.displayed(items[i])
                    MobileViewerPage(
                        item: item,
                        isCurrent: isCurrent,
                        showsChrome: chromeVisible,
                        resolvedMediaKind: resolvedMediaKinds[item.uid],
                        libraryModel: libraryModel,
                        imageStore: imageStore,
                        liveTextHighlighted: isCurrent && liveTextHighlighted,
                        onLiveTextAvailable: { uid, available in
                            if available {
                                liveTextUID = uid
                            } else if liveTextUID == uid {
                                liveTextUID = nil
                                liveTextHighlighted = false
                            }
                        },
                        onToggleChrome: {
                            withAnimation(
                                MobileViewerMotionPolicy.animation(
                                    .easeInOut(duration: 0.2), reduceMotion: reduceMotion
                                )
                            ) {
                                chromeVisible.toggle()
                            }
                        },
                        onCloseRequested: { dismiss() }
                    )
                    .id(item.uid)
                }
            }
            // The Live Photo status sits on the media inside the safe area, below the navigation bar.
            .overlay(alignment: .topLeading) {
                if currentBaseItem?.isLivePhoto == true {
                    viewerBadge(.live)
                }
            }
            // The original of an edited photo is marked in the same place; such a photo is never a Live Photo.
            .overlay(alignment: .topLeading) {
                if let base = currentBaseItem, editedOriginal.isShowingOriginal(of: base.uid) {
                    viewerBadge(.original)
                }
            }
            // A series shows its photo count in the same place; a burst is never a Live Photo.
            .overlay(alignment: .topLeading) {
                if let seriesItems = currentSeriesItems {
                    viewerSeriesButton(count: seriesItems.count)
                }
            }
            // The filmstrip is bottom safe-area content, the Photos-app contract: the media refits when the chrome
            // toggles, and the native bottom bar stacks below the strip.
            .safeAreaInset(edge: .bottom, spacing: 0) { viewerBottomAccessory }
            .overlay {
                UndoNoticeOverlay(
                    notice: Binding(get: { libraryModel.undoNotice }, set: { libraryModel.undoNotice = $0 }))
            }
            // The principal item draws both lines. A blank title string would render as quotation marks while
            // a known location resolves, so the reserved line is hidden by opacity instead, as on the Mac.
            .navigationTitle(viewerTitle.reservesLocationLine ? viewerTitle.line2 : viewerTitle.line1)
            .toolbarTitleDisplayMode(.inline)
            .toolbar { viewerToolbar }
            // The media background is always black; the bars keep light glyphs and titles over it.
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
            // One tap hides both bars, the filmstrip, the status bar and the home indicator together.
            .toolbarVisibility(chromeVisible ? .automatic : .hidden, for: .navigationBar, .bottomBar)
            .background { keyboardCommands }
        }
        // The app shell passes the brand tint into this cover. Bar glyphs over the photo keep the system's light
        // appearance, like the Photos app; the information inspector outside the stack keeps the brand tint.
        .tint(nil)
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
        .task {
            // Register the viewer's transient display cache with the shared memory governor (identity-keyed:
            // a newly opened viewer replaces the previous registration; the weak capture makes a dismissed
            // viewer's handler a no-op). Under `.minimal` the store purges every page except the visible one.
            UIKitMemoryPressureCoordinator.shared.attach(imageStore) {
                [weak imageStore] tier in
                imageStore?.applyMemoryPressure(scale: tier.budgetScale, purge: tier.requiresImmediatePurge)
            }
        }
        .task(id: currentBaseItem?.uid) {
            guard let currentBaseItem else { return }
            await loadBurst(for: currentBaseItem)
        }
        .task(id: metadataTaskID) {
            await resolveCurrentTitleMetadata()
        }
        .onChange(of: mapAndPlacesEnabled) { _, _ in
            titleMetadataCoordinator.cancelAll()
            metadataRequestGeneration &+= 1
        }
        .onChange(of: libraryModel.pendingPresentation.revision) { _, _ in followLibraryReplacements() }
        // A native inspector: a trailing column beside the media in regular iPad windows, the familiar sheet in
        // compact widths. The immersive viewer, its pager and its gestures stay mounted in both cases.
        .inspector(isPresented: $showInfo) {
            if let item = currentBaseItem {
                MobileViewerInfoSheet(
                    item: item,
                    metadataLoadState: metadataLoadState,
                    albumTitles: albumTitles,
                    canLoadAlbumMemberships: libraryModel.facade?.albums != nil,
                    isLoadingAlbumMemberships: isLoadingAlbumMemberships,
                    albumMembershipsLoadFailed: albumMembershipsLoadFailed,
                    placeName: mapAndPlacesEnabled ? titleMetadataState.resolution?.placeName : nil,
                    onRetry: retryCurrentMetadata,
                    onClose: { showInfo = false }
                )
                .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
            }
        }
        .fullScreenCover(item: $seriesModel) { model in
            MobileSeriesFavoritesScreen(model: model, libraryModel: libraryModel)
        }
        .mobileSharePresentation(selection: selection)
        .mobileSelectionAlerts(
            selection: selection,
            trashTitle: String(localized: "viewer.trash_title"),
            trashMessage: String(localized: "viewer.trash_message"),
            trashConfirm: String(localized: "viewer.trash_confirm")
        ) { confirmMoveToTrash() }
        .alert(String(localized: "viewer.restore_failed_title"), isPresented: $showRestoreError) {
            Button(L10n.string("action.ok"), role: .cancel) {}
        } message: {
            Text(String(localized: "viewer.restore_failed_message"))
        }
        .alert(String(localized: "viewer.favorite_failed_title"), isPresented: $showFavoriteError) {
            Button(L10n.string("action.ok"), role: .cancel) {}
        } message: {
            Text(String(localized: "viewer.favorite_failed_message"))
        }
        .alert(
            saveToLibraryMessage ?? "",
            isPresented: Binding(
                get: { saveToLibraryMessage != nil },
                set: { if !$0 { saveToLibraryMessage = nil } }
            )
        ) {
            Button(L10n.string("action.ok"), role: .cancel) { saveToLibraryMessage = nil }
        }
        .albumActionFailureAlert(libraryModel.albumActions)
        .onChange(of: currentBaseItem?.uid) { _, uid in
            cancelViewerMutationPresentation()
            liveTextHighlighted = false
            visibleThumbnail?.select(uid)
            editedOriginal.pageChanged(to: uid)
            lookUpEditedOriginal()
        }
        // The library may still load when the viewer opens; the photo on screen then asks as soon as it is ready.
        .onChange(of: editedOriginalProvider != nil) { _, available in
            if available, let provider = editedOriginalProvider { editedOriginalLookup.providerAvailable(provider) }
        }
        // A full-screen cover over the viewer, such as the series selection, ends the access of the shown copy.
        .onAppear { visibleThumbnail?.reopen(currentBaseItem?.uid) }
        .onAppear { lookUpEditedOriginal() }
        .onDisappear {
            cancelViewerMutationPresentation()
            titleMetadataCoordinator.cancelAll()
            visibleThumbnail?.end()
            editedOriginalLookup.cancel()
        }
        .animation(
            MobileViewerMotionPolicy.animation(.smooth(duration: 0.24), reduceMotion: reduceMotion),
            value: burstSelection.hasFilmstrip
        )
    }

    /// Bottom safe-area content below the media: the route filmstrip. It leaves with the bars on a chrome tap,
    /// so the media refits to the full window the way the Photos app does. The strip keeps its bounded UIKit
    /// collection view; it is not a bar item, so the system never moves it to a vertical bar.
    @ViewBuilder private var viewerBottomAccessory: some View {
        if chromeVisible {
            let profile = chromeLayoutProfile
            MobileViewerFilmstrip(
                items: items,
                selectedUID: currentBaseItem?.uid,
                feed: libraryModel.thumbnailFeed,
                itemSide: min(46, profile.filmstripHeight),
                allowsVisibleDuplicateThumbnails: duplicateGroup != nil,
                onSelect: selectPage
            )
            .frame(height: profile.filmstripHeight)
            .padding(.horizontal, MobileViewerBottomLayout.horizontalPadding)
            .padding(.top, profile.rowSpacing)
            .padding(.bottom, profile.bottomPadding)
            .frame(maxWidth: .infinity)
            .transition(.opacity)
        }
    }

    private var isCompactLandscape: Bool { verticalSizeClass == .compact }
    private var chromeLayoutProfile: ViewerChromeLayoutProfile {
        MobileViewerBottomLayout.profile(compactLandscape: isCompactLandscape)
    }

    /// Native bar content. Close leads the navigation bar and the more-actions menu trails it; the per-photo
    /// actions are bottom bar items with a symbol and a title, so the system can show either representation.
    /// Regular iPad windows move the bottom bar items into the navigation bar; iPhone Duo moves both bars to
    /// the vertical edge. Photos and videos share this one toolbar, so paging never inserts or removes items.
    @ToolbarContentBuilder private var viewerToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) { viewerTitleView }
        viewerCloseItem
        viewerMoreActions
        // A group of duplicates keeps this toolbar: Keep This Copy takes the place of Share, which stays in the
        // more-actions menu, and Merge takes the place of the mutation.
        ToolbarItem(placement: .bottomBar) {
            if let duplicateGroup { duplicateKeepButton(duplicateGroup) } else { viewerShareButton }
        }
        .mobileVisibilityPriority(.high)
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItemGroup(placement: .bottomBar) {
            // Shared photos cannot carry the account's favorite tag; the context is fixed for the presentation.
            if context.allowsFavorites { viewerFavoriteButton }
            viewerAlbumButton
            viewerInfoButton
        }
        // Favorite, Album, and Info are the first to leave a compressed bar; the overflow menu keeps their titles.
        .mobileVisibilityPriority(.low)
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            if let duplicateGroup { duplicateMergeButton(duplicateGroup) } else { viewerMutationButton }
        }
        .mobileVisibilityPriority(.high)
    }

    /// Keeps the photo shown when its group is merged. "Kept" with a filled checkmark once a merge keeps it.
    private func duplicateKeepButton(_ group: MobileDuplicateViewerGroup) -> some View {
        let uid = currentBaseItem?.uid
        let title = uid.map { group.model.keepTitle(for: $0) } ?? ""
        let symbol = uid.map { group.model.keepSymbol(for: $0) } ?? "checkmark.circle"
        return Button {
            guard let uid else { return }
            group.model.keep(uid)
        } label: {
            Label(title, systemImage: symbol)
        }
        .disabled(!(uid.map { group.model.canKeep($0) } ?? false))
        .accessibilityLabel(title)
        .accessibilityIdentifier("duplicates.viewer.keep")
    }

    /// Merges the group of the photo on screen with the photo shown as kept, like Merge in Apple Photos, and closes
    /// the viewer. The group is found at the tap: it can have split since the viewer opened.
    private func duplicateMergeButton(_ group: MobileDuplicateViewerGroup) -> some View {
        let title = group.model.mergeTitle
        let uid = currentBaseItem?.uid
        return Button {
            guard let uid else { return }
            dismiss()
            Task { await group.model.merge(containing: uid) }
        } label: {
            Label(title, systemImage: group.model.mergeSymbol)
        }
        .disabled(!(uid.map { group.model.canMerge(containing: $0) } ?? false))
        .accessibilityLabel(title)
        .accessibilityIdentifier("duplicates.viewer.merge")
    }

    /// Close is the primary navigation control: it stays at the top of a vertical bar and never overflows.
    private var viewerCloseItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                dismiss()
            } label: {
                Label(String(localized: "viewer.close_a11y"), systemImage: "chevron.left")
            }
            .accessibilityLabel(String(localized: "viewer.close_a11y"))
        }
        .mobileVisibilityPriority(.high)
    }

    /// The system overflow menu owns the ellipsis on iOS 27 (HIG: reserve the ellipsis for overflow). iOS 26 has
    /// no system overflow, so it keeps the app-owned ellipsis menu with the same actions.
    @ToolbarContentBuilder private var viewerMoreActions: some ToolbarContent {
        if #available(iOS 27.0, *) {
            ToolbarOverflowMenu {
                viewerActionMenu
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    viewerActionMenu
                } label: {
                    if selection.isBusy || isRestoring {
                        ProgressSpinner()
                    } else {
                        Label(String(localized: "viewer.more_actions_a11y"), systemImage: "ellipsis")
                    }
                }
                .disabled(currentBaseItem == nil || selection.isBusy || isRestoring)
                .accessibilityLabel(String(localized: "viewer.more_actions_a11y"))
            }
            .mobileVisibilityPriority(.low)
        }
    }

    private var viewerTitleView: some View {
        let title = viewerTitle
        return VStack(spacing: 1) {
            Text(verbatim: title.line1)
                .font(.headline)
                .opacity(title.reservesLocationLine ? 0 : 1)
            Text(verbatim: title.line2)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }

    /// The Apple-Photos-style two-line bar title: location or date first, date/time and position second. While a
    /// known location resolves, line one stays blank so the title does not jump from date to place.
    private var viewerTitle: ViewerTitle {
        guard let current = currentBaseItem else { return ViewerTitle(line1: "", line2: "") }
        return ViewerTitleFormatter.make(
            captureDate: current.captureTime,
            index: index,
            total: items.count,
            locationName: mapAndPlacesEnabled ? titleMetadataState.resolution?.placeName : nil,
            locationIsResolving: mapAndPlacesEnabled
                && titleMetadataState.shouldReservePlaceNameLine(
                    hasKnownLocation: libraryModel.locationIndex.hasKnownLocation(current.uid)
                ),
            filename: metadataLoadState.metadata?.filename
        )
    }

    /// A media status badge leaves with the chrome and never steals paging, press or dismiss gestures.
    private func viewerBadge(_ badge: MobileViewerBadge) -> some View {
        badge
            .padding(16)
            .opacity(chromeVisible ? 1 : 0)
            .allowsHitTesting(false)
            // It leaves VoiceOver with the rest of the chrome and returns with it.
            .accessibilityHidden(!chromeVisible)
    }

    /// The Photos-style series control: the photo count with a disclosure chevron, in system Liquid Glass. It
    /// leaves with the chrome. Opening it shows every photo of the series in the "Select Favorites" mode.
    private func viewerSeriesButton(count: Int) -> some View {
        Button(action: openSeriesSelection) {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.down.right")
                Text(String(localized: "viewer.series_button \(count)"))
                Image(systemName: "chevron.right")
                    .imageScale(.small)
            }
            .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .opacity(chromeVisible ? 1 : 0)
        .allowsHitTesting(chromeVisible)
        .accessibilityHidden(!chromeVisible)
        .accessibilityLabel(String(localized: "viewer.series_button \(count)"))
        .accessibilityHint(String(localized: "viewer.series_button_hint"))
        .accessibilityIdentifier("viewer.seriesButton")
    }

    private var viewerShareButton: some View {
        Button(action: shareCurrentItem) {
            if selection.isBusy {
                ProgressView()
            } else {
                Label(String(localized: "viewer.share_action"), systemImage: "square.and.arrow.up")
            }
        }
        .disabled(currentBaseItem == nil || selection.isBusy)
        .accessibilityLabel(String(localized: "viewer.share_action"))
    }

    private var viewerFavoriteButton: some View {
        let uid = currentBaseItem?.uid
        let favorite = uid.map { libraryModel.displayedFavoriteUIDs.contains($0) } ?? false
        let busy = uid.map { libraryModel.favoriteMutationsInFlight.contains($0) } ?? false
        let title =
            favorite
            ? String(localized: "viewer.remove_favorite_action")
            : String(localized: "viewer.favorite_action")
        return Button {
            guard let uid else { return }
            toggleFavorite(uid)
        } label: {
            if busy {
                ProgressView()
            } else {
                Label(title, systemImage: favorite ? "heart.fill" : "heart")
            }
        }
        .disabled(uid == nil || busy)
        .accessibilityLabel(title)
    }

    /// The grid's Add to Album button for the open photo. Only library photos can join an album.
    @ViewBuilder private var viewerAlbumButton: some View {
        if viewerMutationAction == .moveToTrash, let coordinator = libraryModel.albumActions {
            AlbumAddButton(
                coordinator: coordinator,
                photoUIDs: currentBaseItem.map { [$0.uid] } ?? [],
                isPresented: $showAlbumPicker,
                arrowEdge: .bottom,
                onAlbumsChanged: { libraryModel.noteAlbumsChanged() },
                // The more-actions menu lists the photo's albums; read them again after adding.
                onCompleted: { _ in metadataRequestGeneration &+= 1 }
            )
            .disabled(selection.isBusy)
        }
    }

    private var viewerInfoButton: some View {
        Button {
            showInfo = true
        } label: {
            Label(String(localized: "viewer.info_action"), systemImage: "info.circle")
        }
        .disabled(currentBaseItem == nil)
        .accessibilityLabel(String(localized: "viewer.info_action"))
    }

    /// Move to Trash in the library, Restore in Recently Deleted, Save to Library in a shared album: one slot,
    /// the shared mutation policy.
    private var viewerMutationButton: some View {
        let action = viewerMutationAction
        let title = viewerMutationTitle(action)
        return Button(role: action == .moveToTrash ? .destructive : nil, action: requestViewerMutation) {
            if isRestoring || isSavingToLibrary || selection.isTrashing {
                ProgressView()
            } else {
                Label(title, systemImage: viewerMutationSystemImage(action))
            }
        }
        .disabled(currentBaseItem == nil || isRestoring || isSavingToLibrary || selection.isBusy)
        .accessibilityLabel(title)
    }

    private func viewerMutationTitle(_ action: ViewerMutationAction) -> String {
        switch action {
        case .moveToTrash: String(localized: "viewer.move_to_trash_action")
        case .restore: String(localized: "viewer.restore_action")
        case .saveToLibrary: L10n.string("library.save_to_library")
        }
    }

    private func viewerMutationSystemImage(_ action: ViewerMutationAction) -> String {
        switch action {
        case .moveToTrash: "trash"
        case .restore: "arrow.uturn.backward"
        case .saveToLibrary: PhotoContextMenuAction.saveToLibrary.systemImage
        }
    }

    @ViewBuilder
    private var viewerActionMenu: some View {
        if !albumTitles.isEmpty {
            Section(L10n.string("infopanel.albums")) {
                ForEach(albumTitles, id: \.self) { title in
                    Label(title, systemImage: "rectangle.stack")
                }
            }
        }
        Button {
            shareCurrentItem()
        } label: {
            Label(String(localized: "viewer.share_action"), systemImage: "square.and.arrow.up")
        }
        .disabled(currentBaseItem == nil || selection.isBusy)

        if let base = currentBaseItem, editedOriginal.canShowOriginal(of: base.uid) {
            let showing = editedOriginal.isShowingOriginal(of: base.uid)
            Button {
                editedOriginal.toggle(base.uid)
            } label: {
                Label(
                    showing ? L10n.string("viewer.show_edited") : L10n.string("viewer.show_original"),
                    systemImage: showing ? "wand.and.rays" : "wand.and.rays.inverse"
                )
            }
        }

        if currentBaseItem?.uid != nil, liveTextUID == currentBaseItem?.uid {
            Button {
                liveTextHighlighted.toggle()
            } label: {
                Label(
                    liveTextHighlighted ? L10n.string("viewer.live_text_hide") : L10n.string("viewer.live_text_show"),
                    systemImage: MobileLiveText.systemImage
                )
            }
        }

        Divider()

        switch viewerMutationAction {
        case .restore, .saveToLibrary:
            Button {
                requestViewerMutation()
            } label: {
                Label(
                    viewerMutationTitle(viewerMutationAction),
                    systemImage: viewerMutationSystemImage(viewerMutationAction))
            }
            .disabled(currentBaseItem == nil || isRestoring || isSavingToLibrary || selection.isBusy)
        case .moveToTrash:
            Button(role: .destructive) {
                requestViewerMutation()
            } label: {
                Label(String(localized: "viewer.move_to_trash_action"), systemImage: "trash")
            }
            .disabled(currentBaseItem == nil || isRestoring || selection.isBusy)
        }
    }

    private var viewerMutationAction: ViewerMutationAction {
        ViewerMutationPolicy.action(for: context)
    }

    private struct MetadataTaskID: Equatable {
        let uid: PhotoUID?
        let generation: UInt64
    }

    private var metadataTaskID: MetadataTaskID {
        MetadataTaskID(uid: currentBaseItem?.uid, generation: metadataRequestGeneration)
    }

    private func resolveCurrentTitleMetadata() async {
        titleMetadataCoordinator.prepare(items: items, around: index)
        metadataLoadState = .idle
        albumTitles = []
        albumMembershipsLoadFailed = false
        guard let item = currentBaseItem else { return }
        let uid = item.uid
        titleMetadataState = titleMetadataCoordinator.state(for: uid)
        metadataLoadState = .loading
        let albums = libraryModel.facade?.albums
        isLoadingAlbumMemberships = albums != nil
        let coordinator = titleMetadataCoordinator
        // A retry, a privacy change or an album change keeps the photo but starts a new run.
        let run = metadataTaskID
        await ViewerInfoPublication.run(
            metadata: { await coordinator.resolve(item) },
            memberships: { await Self.albumTitles(of: uid, in: albums) },
            isCurrent: { metadataTaskID == run },
            publishMetadata: { resolution in
                titleMetadataState = .resolved(resolution)
                metadataLoadState = resolution.metadataLoadState
                guard let metadata = resolution.metadata else { return }
                let resolvedKind = VideoContentSniffer.kind(mimeType: metadata.mimeType)
                if resolvedKind != .unknown {
                    resolvedMediaKinds[uid] = resolvedKind
                }
            },
            publishMemberships: { applyAlbumMembershipResult($0) }
        )
    }

    private func retryCurrentMetadata() {
        guard let uid = currentBaseItem?.uid else { return }
        titleMetadataCoordinator.invalidate(uid)
        metadataRequestGeneration &+= 1
    }

    private static func albumTitles(
        of uid: PhotoUID, in repository: AlbumsRepository?
    ) async -> Result<[String], Error>? {
        guard let repository else { return nil }
        do {
            return .success(try await repository.albumMembershipTitles(for: uid))
        } catch {
            return .failure(error)
        }
    }

    @MainActor
    private func applyAlbumMembershipResult(_ result: Result<[String], Error>?) {
        isLoadingAlbumMemberships = false
        switch result {
        case .success(let titles):
            albumTitles = titles
            albumMembershipsLoadFailed = false
        case .failure:
            albumTitles = []
            albumMembershipsLoadFailed = true
        case nil:
            albumTitles = []
            albumMembershipsLoadFailed = false
        }
    }

    /// Shares what the page shows: the original of an edited photo while it is shown.
    private func shareCurrentItem() {
        guard let base = currentBaseItem, libraryModel.backend != nil else { return }
        let item = editedOriginal.displayed(base)
        let items = burstBelongsToCurrentPage ? burstSelection.exportItems(current: item) : [item]
        selection.startShare(
            items: items, backend: libraryModel.viewerMedia,
            failureMessage: String(localized: "viewer.share_failed")
        )
    }

    private func requestViewerMutation() {
        guard let item = currentBaseItem else { return }
        switch viewerMutationAction {
        case .moveToTrash:
            selection.selected = [item.uid]
            selection.showTrashConfirm = true
        case .restore:
            restore(item)
        case .saveToLibrary:
            saveToLibrary(item)
        }
    }

    /// Copies the shared photo into the own library. The result message confirms the copy or names the failure.
    private func saveToLibrary(_ item: PhotoItem) {
        guard !isSavingToLibrary else { return }
        isSavingToLibrary = true
        Task { @MainActor in
            let result = await libraryModel.saveToLibrary([item.uid])
            isSavingToLibrary = false
            saveToLibraryMessage = result?.message ?? L10n.string("library.save_to_library_failed")
        }
    }

    private func confirmMoveToTrash() {
        guard let item = currentBaseItem else { return }
        selection.performTrash(failureMessage: String(localized: "viewer.trash_failed")) { uids in
            try await libraryModel.trashItems(uids)
            viewerRouter.noteCompletedMutation(uid: item.uid)
            dismiss()
        }
    }

    private func restore(_ item: PhotoItem) {
        guard !isRestoring else { return }
        restoreRequestGeneration &+= 1
        let requestGeneration = restoreRequestGeneration
        let uid = item.uid
        isRestoring = true
        restoreTask = Task { @MainActor in
            do {
                try await libraryModel.restoreItems([item])
                // The remote restore is authoritative even if the viewer paged or disappeared while waiting.
                // Always reconcile the source route; the request generation gates presentation only.
                viewerRouter.noteCompletedMutation(uid: uid)
                restoreTask = nil
                isRestoring = false
                guard requestGeneration == restoreRequestGeneration,
                    currentBaseItem?.uid == uid
                else { return }
                dismiss()
            } catch is CancellationError {
                restoreTask = nil
                isRestoring = false
            } catch {
                restoreTask = nil
                isRestoring = false
                guard requestGeneration == restoreRequestGeneration,
                    currentBaseItem?.uid == uid
                else { return }
                showRestoreError = true
            }
        }
    }

    private func toggleFavorite(_ uid: PhotoUID) {
        favoriteTask?.cancel()
        favoriteRequestGeneration &+= 1
        let requestGeneration = favoriteRequestGeneration
        favoriteTask = Task { @MainActor in
            let succeeded = await libraryModel.toggleFavorite(uid)
            guard !Task.isCancelled,
                requestGeneration == favoriteRequestGeneration,
                currentBaseItem?.uid == uid
            else { return }
            favoriteTask = nil
            if !succeeded {
                showFavoriteError = true
            }
        }
    }

    private func cancelViewerMutationPresentation() {
        favoriteRequestGeneration &+= 1
        favoriteTask?.cancel()
        favoriteTask = nil
        restoreRequestGeneration &+= 1
        showFavoriteError = false
        showRestoreError = false
    }

    private var currentBaseItem: PhotoItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    @MainActor
    private func selectPage(_ uid: PhotoUID) {
        guard let selected = pageIndex.index(of: uid) else { return }
        guard selected != index else { return }
        index = selected
    }

    /// Swaps photos that the backup replaced for their replacement; see `ViewerReplacementFollow`.
    private func followLibraryReplacements() {
        guard followsLibraryReplacements else { return }
        let presentation = libraryModel.pendingPresentation
        guard
            let followed = ViewerReplacementFollow.follow(
                items, pages: pageIndex, current: index, replacements: presentation.replacements,
                timeline: presentation.snapshot)
        else { return }
        // A returning UID, such as the tile of a second edit, must not show the image of its last showing.
        imageStore.forget(followed.arrived)
        items = followed.items
        itemsRevision &+= 1
        pageIndex = followed.pages
        index = followed.current
    }

    /// Hardware-keyboard parity with the macOS viewer: arrow keys page, Escape closes. The buttons render
    /// nothing; they only register shortcuts for the presented viewer.
    private var keyboardCommands: some View {
        Group {
            Button("") { stepPage(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { stepPage(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func stepPage(_ delta: Int) {
        let next = index + delta
        guard items.indices.contains(next) else { return }
        index = next
    }

    private var burstBelongsToCurrentPage: Bool {
        burstBaseUID == currentBaseItem?.uid
    }

    /// The series of the current page, once it is loaded. The viewer itself shows only the series' main photo,
    /// as the Photos app does; the other photos open in the "Select Favorites" mode.
    private var currentSeriesItems: [PhotoItem]? {
        burstBelongsToCurrentPage && burstSelection.hasFilmstrip ? burstSelection.items : nil
    }

    private func openSeriesSelection() {
        guard let base = currentBaseItem, let seriesItems = currentSeriesItems, seriesModel == nil else { return }
        let request = MobileSeriesSelectionRequest(seriesMainUID: base.uid, items: seriesItems, focusedUID: base.uid)
        let seriesUIDs = seriesItems.map(\.uid)
        let inLibrary = viewerMutationAction == .moveToTrash
        Task { @MainActor in
            // Recently Deleted and shared albums only browse a series; "Keep Only Favorites" needs the own library.
            let canKeepOnlyFavorites =
                inLibrary ? await libraryModel.canKeepOnlySeriesFavorites(seriesUIDs: seriesUIDs) : false
            guard currentBaseItem?.uid == base.uid, seriesModel == nil else { return }
            seriesModel = MobileSeriesFavoritesModel(
                request: request,
                canKeepOnlyFavorites: canKeepOnlyFavorites,
                keepOnlyFavorites: { favoriteUIDs, onProgress in
                    try await libraryModel.keepOnlySeriesFavorites(
                        seriesMainUID: base.uid,
                        seriesUIDs: seriesUIDs,
                        favoriteUIDs: favoriteUIDs,
                        onProgress: onProgress
                    )
                },
                abandonKeepOnlyFavorites: {
                    libraryModel.abandonKeepOnlySeriesFavorites(seriesMainUID: base.uid)
                },
                onFinished: { seriesDissolved in
                    seriesModel = nil
                    guard seriesDissolved else { return }
                    // The series left the library: the source route reconciles and the viewer closes.
                    viewerRouter.noteCompletedMutation(uid: base.uid)
                    dismiss()
                }
            )
        }
    }

    /// Asks for the original of the settled page, once it stayed for the dwell; see `EditedPhotoOriginalLookup`.
    private func lookUpEditedOriginal() {
        editedOriginalLookup.settled(on: currentBaseItem, provider: editedOriginalProvider) { base, original in
            editedOriginal.record(original, of: base.uid)
        }
    }

    private var editedOriginalProvider: (any EditedPhotoOriginalProviding)? {
        libraryModel.backend as? any EditedPhotoOriginalProviding
    }

    @MainActor private func loadBurst(for item: PhotoItem) async {
        burstBaseUID = item.uid
        burstSelection.reset()
        burstSelection.seedKnownGroup(
            for: item,
            knownItems: pageIndex.items(withUIDs: item.burstMemberUIDs, from: items)
        )
        guard let provider = libraryModel.backend,
            burstSelection.beginLoadingIfCandidate(item)
        else { return }
        do {
            let group = try await provider.burstGroup(containing: item.uid)
            guard !Task.isCancelled, currentBaseItem?.uid == item.uid else { return }
            withAnimation(
                MobileViewerMotionPolicy.animation(
                    .smooth(duration: 0.24), reduceMotion: reduceMotion
                )
            ) {
                burstSelection.applyLoadedGroup(group, containing: item)
            }
        } catch {
            guard !Task.isCancelled, currentBaseItem?.uid == item.uid else { return }
            burstSelection.failLoading()
        }
    }
}

/// Native horizontal photo pager: `UIPageViewController(.scroll)` hosting the SwiftUI pages. Chosen over
/// SwiftUI's `TabView(.page)` because it participates in the device-rotation size transition - the current
/// page stays centred and refits throughout the rotation animation instead of snapping afterwards. Selection
/// syncs both ways via the `index` binding; `isCurrent` is re-injected into every live page on change, so
/// pages keep their bounded load/teardown behavior (current page only).
private struct MobileViewerPager<Page: View>: UIViewControllerRepresentable {
    let count: Int
    /// Changes when the collection changes. A page keeps its controller while its photo stays in the collection.
    let revision: Int
    let id: (Int) -> PhotoUID
    @Binding var index: Int
    @ViewBuilder let page: (Int, Bool) -> Page

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: 12]  // the small black gutter between pages, like Photos
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .clear
        pvc.setViewControllers([context.coordinator.pageController(at: index)], direction: .forward, animated: false)
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        // A page that left the collection shifts the later pages. Kept pages move to their new index with their state,
        // such as zoom or playback; setting the visible page again makes the pager ask for fresh neighbours.
        let collectionChanged = context.coordinator.remapPagesIfCollectionChanged()
        // An external index change jumps to that page; user swipes return through the delegate.
        if let visible = (pvc.viewControllers?.first as? HostedPage)?.pageIndex, collectionChanged || visible != index {
            pvc.setViewControllers(
                [context.coordinator.pageController(at: index)],
                direction: visible < index ? .forward : .reverse, animated: false)
        }
        context.coordinator.refreshLivePages()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// Hosts one page and remembers which index it shows (the pager's data source is index-based).
    final class HostedPage: UIHostingController<AnyView> {
        var pageIndex: Int
        let pageID: PhotoUID
        init(index: Int, id: PhotoUID, root: AnyView) {
            self.pageIndex = index
            self.pageID = id
            super.init(rootView: root)
            // The outer SwiftUI layout accounts for device safe areas and the inspector column.
            // A nested page must not apply the pager's cached safe area a second time.
            safeAreaRegions = []
            view.backgroundColor = .clear  // never flash the hosting default background between pages
        }
        @available(*, unavailable)
        @MainActor required dynamic init?(coder: NSCoder) { fatalError("not supported") }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: MobileViewerPager
        /// Live pages by index, kept to a window around the requested page. Evicted pages are still retained
        /// by UIPageViewController while on screen; we only lose SwiftUI-state reuse, and the viewer store's
        /// cache makes a re-created page's image instant.
        private var live: [Int: HostedPage] = [:]
        private var revision: Int

        init(parent: MobileViewerPager) {
            self.parent = parent
            revision = parent.revision
        }

        /// Moves each live page to the new index of its photo and drops the pages whose photo left; true when the
        /// collection changed. Only the few live pages are looked up, near their old index first.
        func remapPagesIfCollectionChanged() -> Bool {
            guard parent.revision != revision else { return false }
            revision = parent.revision
            var remapped: [Int: HostedPage] = [:]
            for page in live.values {
                guard
                    let i = ViewerReplacementFollow.newIndex(
                        of: page.pageID, near: page.pageIndex, count: parent.count, uidAt: parent.id)
                else { continue }
                page.pageIndex = i
                remapped[i] = page
            }
            live = remapped
            return true
        }

        func pageController(at i: Int) -> HostedPage {
            if let vc = live[i] { return vc }
            let vc = HostedPage(index: i, id: parent.id(i), root: AnyView(parent.page(i, i == parent.index)))
            live[i] = vc
            live = live.filter { abs($0.key - i) <= 2 }
            return vc
        }

        /// Re-inject `isCurrent` into every live page after a selection change, preserving the pages'
        /// current-only load/teardown gating.
        func refreshLivePages() {
            for (i, vc) in live { vc.rootView = AnyView(parent.page(i, i == parent.index)) }
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let i = (viewController as? HostedPage)?.pageIndex, i > 0 else { return nil }
            return pageController(at: i - 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let i = (viewController as? HostedPage)?.pageIndex, i < parent.count - 1 else { return nil }
            return pageController(at: i + 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController], transitionCompleted completed: Bool
        ) {
            guard completed, let i = (pageViewController.viewControllers?.first as? HostedPage)?.pageIndex else {
                return
            }
            parent.index = i  // The binding update refreshes live pages and their current state.
        }
    }
}

/// A single viewer page - a zoomable image, or a native video player for video items.
private struct MobileViewerPage: View {
    let item: PhotoItem
    let isCurrent: Bool
    let showsChrome: Bool
    let resolvedMediaKind: MediaKind?
    let libraryModel: MobileLibraryModel
    let imageStore: UIKitViewerImageStore
    let liveTextHighlighted: Bool
    let onLiveTextAvailable: (PhotoUID, Bool) -> Void
    let onToggleChrome: () -> Void
    let onCloseRequested: () -> Void

    var body: some View {
        if MobileViewerMediaRoute.isVideo(item: item, resolvedKind: resolvedMediaKind) {
            MobileVideoPage(
                item: item,
                isCurrent: isCurrent,
                showsChrome: showsChrome,
                libraryModel: libraryModel,
                onToggleChrome: onToggleChrome,
                onCloseRequested: onCloseRequested
            )
        } else {
            MobileImagePage(
                item: item,
                isCurrent: isCurrent,
                imageStore: imageStore,
                streamer: libraryModel.backend,
                liveTextHighlighted: liveTextHighlighted,
                onLiveTextAvailable: onLiveTextAvailable,
                onToggleChrome: onToggleChrome,
                onCloseRequested: onCloseRequested
            )
        }
    }
}

/// Staged, bounded page loading (thumbnail to screen-bounded display image): the grid thumbnail shows instantly,
/// then, for the current page only, a mid-size preview or bounded original fallback is fetched and decoded
/// off-main to a screen-bounded size and swapped in. Swipe-preview neighbours never fetch/decode (no fan-out),
/// and swiping away cancels an in-flight load (the `.task(id:)` re-runs on the isCurrent flip). No full-resolution
/// decode just because a page appeared.
struct MobileImagePage: View {
    let item: PhotoItem
    let isCurrent: Bool
    let imageStore: UIKitViewerImageStore
    /// The shared streamer used to preload the current Live Photo's encrypted motion clip.
    let streamer: (any VideoStreamProvider)?
    var liveTextHighlighted = false
    var onLiveTextAvailable: (PhotoUID, Bool) -> Void = { _, _ in }
    let onToggleChrome: () -> Void
    let onCloseRequested: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    /// The displayed photo rect (aspect-fit area, zoom/pan-transformed) in page coordinates, reported live by
    /// the zoomable scroll view. Anchors the motion overlay to the photo, not the viewer.
    @State private var photoFrame: CGRect?
    /// In-flight zoom-tier decode - replaced (cancelling the old fetch) when the zoom settles elsewhere.
    @State private var zoomDecodeTask: Task<Void, Never>?
    /// The decode cap of the image currently displayed (0 = grid thumbnail). Tier assignments are gated on
    /// `newCap >= displayedCap`, so a slower base-tier load cannot replace a sharper zoom decode that
    /// landed while it was still in flight.
    @State private var displayedCap = 0
    /// Real decoded pixels currently on screen. Request caps alone are not quality evidence: the opening
    /// transition can briefly report a thumbnail-sized viewport and produce a smaller preview than the grid image.
    @State private var displayedLongestPixelSide = 0
    /// Live Photos keep the loading presentation until original bytes have produced the bounded sharp still.
    /// Regular photos retain the existing preview-first behavior and fetch original bytes only for settled zoom.
    @State private var isFullResolutionStillReady = false
    @State private var didFullResolutionStillFail = false
    /// Shared Live Photo motion controller for the current page.
    @State private var motion = LivePhotoMotionController()
    /// On-device Live Text of the displayed still, for the current page only.
    @State private var liveTextAnalysis: ImageAnalysis?
    /// Actual page viewport, including iPad split-view and future resizable form factors. A global
    /// screen bound over-decodes small windows and becomes wrong after a live resize.
    @State private var viewportSize: CGSize = .zero

    /// Shared still-to-motion transition timing.
    private let transition = ViewerMediaTransitionStyle.standard
    var body: some View {
        ZStack {
            if let image {
                MobileZoomableImage(
                    image: image,
                    reduceMotion: reduceMotion,
                    onSingleTap: onToggleChrome,
                    onCloseRequested: onCloseRequested,
                    onMotionStart: item.isLivePhoto
                        ? {
                            motion.play(for: item, streamer: streamer) { isCurrent }
                        } : nil,
                    onMotionStop: item.isLivePhoto ? { motion.stop() } : nil,
                    onPhotoFrameChanged: { photoFrame = $0 },
                    onZoomSettled: { loadZoomedDecodeIfNeeded(zoom: $0) },
                    liveTextAnalysis: isCurrent ? liveTextAnalysis : nil,
                    liveTextHighlighted: isCurrent && liveTextHighlighted
                )
            } else if livePhotoReadiness == .notApplicable {
                ProgressView().tint(.white)
            }

            // The paired motion clip, crossfaded in over the still while the press is held (once preloaded).
            // Framed to the displayed photo rect (zoom- and pan-transformed), so a zoomed-in Live Photo plays
            // its motion at the same zoom/position as the still - never an unzoomed clip floating on top.
            if item.isLivePhoto, let player = motion.player {
                if let pf = photoFrame {
                    MobileMotionPlayerLayer(player: player)
                        .frame(width: pf.width, height: pf.height)
                        .position(x: pf.midX, y: pf.midY)
                        .allowsHitTesting(false)
                        .opacity(motion.isPlaying ? 1 : 0)
                        .animation(
                            MobileViewerMotionPolicy.animation(
                                .easeInOut(duration: transition.opacityDuration), reduceMotion: reduceMotion
                            ),
                            value: motion.isPlaying
                        )
                        .zIndex(1)
                } else {
                    MobileMotionPlayerLayer(player: player)
                        .allowsHitTesting(false)
                        .opacity(motion.isPlaying ? 1 : 0)
                        .animation(
                            MobileViewerMotionPolicy.animation(
                                .easeInOut(duration: transition.opacityDuration), reduceMotion: reduceMotion
                            ),
                            value: motion.isPlaying
                        )
                        .zIndex(1)
                }
            }

            if isCurrent {
                switch livePhotoReadiness {
                case .loading:
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .padding(16)
                        .glassEffect(in: Circle())
                        .allowsHitTesting(false)
                        .zIndex(2)
                case .failed:
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .padding(14)
                        .glassEffect(in: Circle())
                        .accessibilityLabel(L10n.string("viewer.playback_failed"))
                        .allowsHitTesting(false)
                        .zIndex(2)
                case .notApplicable, .ready:
                    EmptyView()
                }
            }
        }
        // Gentle scale under the still-to-motion crossfade.
        .scaleEffect(motion.isPlaying ? transition.liveMotionScale : 1)
        .animation(
            MobileViewerMotionPolicy.animation(
                .easeInOut(duration: transition.scaleDuration), reduceMotion: reduceMotion
            ),
            value: motion.isPlaying
        )
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            viewportSize = newSize
        }
        .task(
            id: ViewerImageLoadPolicy.LoadIdentity(
                uid: item.uid,
                isCurrent: isCurrent,
                maxPixelSize: displayLoadCap
            )
        ) {
            await load(maxPixelSize: displayLoadCap)
        }
        .task(id: MobileLivePhotoMotionTaskID(item: item, isCurrent: isCurrent)) {
            prepareOrStopMotion()
        }
        .task(id: MobileLiveTextTaskID(uid: item.uid, isCurrent: isCurrent, image: image.map(ObjectIdentifier.init))) {
            await analyzeLiveText()
        }
        .onChange(of: isCurrent) { _, current in
            if !current { cancelZoomDecode() }
        }
        .onAppear {
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice(
                    "[ViewerPerf] page appear uid=\(MobileViewerLog.short(item.uid), privacy: .public) current=\(isCurrent) kind=photo"
                )
            }
        }
        .onDisappear {
            cancelZoomDecode()
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice(
                    "[ViewerPerf] page disappear uid=\(MobileViewerLog.short(item.uid), privacy: .public)")
            }
            motion.teardown()
        }
    }

    /// Recognizes text in the displayed still of the current page. A sharper image replaces the analysis; the grid
    /// thumbnail shown while the display image loads is skipped.
    private func analyzeLiveText() async {
        guard isCurrent, let image, displayedCap > 0 else {
            liveTextAnalysis = nil
            onLiveTextAvailable(item.uid, false)
            return
        }
        let analysis = await MobileLiveText.analyze(image)
        guard !Task.isCancelled, isCurrent else { return }
        liveTextAnalysis = analysis
        onLiveTextAvailable(item.uid, analysis != nil)
    }

    /// Preloads only the current page. The task identity excludes viewport changes, so resizing cannot restart it.
    private func prepareOrStopMotion() {
        guard item.isLivePhoto, isCurrent else {
            motion.teardown()
            return
        }
        motion.prepare(for: item, streamer: streamer) { isCurrent }
    }

    private var livePhotoReadiness: LivePhotoCompositeReadiness {
        LivePhotoCompositeReadiness.resolve(
            requiresMotion: LivePhotoMotionPolicy.shouldPrepare(item: item, hasStreamer: streamer != nil),
            isFullResolutionStillReady: isFullResolutionStillReady,
            didFullResolutionStillFail: didFullResolutionStillFail,
            motionState: motion.loadState,
            isMotionRequested: motion.isPlayRequested
        )
    }

    private var displayLoadCap: Int {
        max(
            displayedCap,
            ViewerImageLoadPolicy.displayMaxPixelSize(viewportPoints: viewportSize, scale: displayScale)
        )
    }

    private func load(maxPixelSize cap: Int) async {
        // Install the immediate grid thumbnail when no image is mounted: from RAM, else from the feed's disk tier.
        if image == nil {
            var thumb = imageStore.thumbnail(for: item.uid)
            if thumb == nil { thumb = await imageStore.cachedThumbnail(for: item.uid) }
            if let thumb, !Task.isCancelled, image == nil {
                _ = installIfNotLowerQuality(thumb)
                if MobileViewerLog.isEnabled {
                    MobileViewerLog.logger.notice(
                        "[ViewerPerf] display uid=\(MobileViewerLog.short(item.uid), privacy: .public) tier=thumbnail")
                }
            }
        }
        // Load a screen-bounded preview for the current page only.
        guard ViewerImageLoadPolicy.shouldLoadDisplay(distanceFromCurrent: isCurrent ? 0 : 1) else { return }
        if let display = await imageStore.displayImage(for: item.uid, maxPixelSize: cap), !Task.isCancelled,
            cap >= displayedCap, installIfNotLowerQuality(display, requestedCap: cap)
        {
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice(
                    "[ViewerPerf] display uid=\(MobileViewerLog.short(item.uid), privacy: .public) tier=\(display.source, privacy: .public)"
                )
            }
        }
        await loadFullResolutionLivePhotoStill(maxPixelSize: cap)
        // The full original remains deferred until a settled zoom requests more pixels. Live Photos load the
        // bounded still needed for their composite readiness; the paired motion preloads independently.
    }

    private func loadFullResolutionLivePhotoStill(maxPixelSize: Int) async {
        guard LivePhotoMotionPolicy.shouldPrepare(item: item, hasStreamer: streamer != nil),
            isCurrent
        else { return }
        didFullResolutionStillFail = false
        guard let sharp = await imageStore.originalImage(for: item.uid, maxPixelSize: maxPixelSize),
            !Task.isCancelled, isCurrent
        else {
            if !Task.isCancelled, isCurrent { didFullResolutionStillFail = true }
            return
        }
        _ = installIfNotLowerQuality(sharp, requestedCap: maxPixelSize)
        isFullResolutionStillReady = true
        if MobileViewerLog.isEnabled {
            MobileViewerLog.logger.notice(
                "[ViewerPerf] display uid=\(MobileViewerLog.short(item.uid), privacy: .public) tier=livePhotoOriginal"
            )
        }
    }

    /// After zoom settles beyond fit, decode the original at the size this zoom needs and swap it in.
    /// The swap is seamless: only `UIImageView.image` changes (same aspect ratio), and the scroll
    /// view's zoomScale/contentOffset are untouched, so nothing moves - the pixels just get sharper. The store
    /// serves the bytes from the E2EE originals cache (already fetched by the base tier) and its
    /// `decodedCap` cache gate turns repeat settles at the same zoom into instant hits.
    private func loadZoomedDecodeIfNeeded(zoom: CGFloat) {
        guard zoom > 1.01, isCurrent, viewportSize.width > 0, viewportSize.height > 0 else { return }
        let cap = ViewerImageLoadPolicy.zoomedMaxPixelSize(
            viewportPoints: viewportSize, scale: displayScale, zoom: zoom)
        cancelZoomDecode()
        zoomDecodeTask = Task {
            guard let sharp = await imageStore.originalImage(for: item.uid, maxPixelSize: cap),
                !Task.isCancelled, isCurrent
            else { return }
            _ = installIfNotLowerQuality(sharp, requestedCap: cap)
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice(
                    "[ViewerPerf] display uid=\(MobileViewerLog.short(item.uid), privacy: .public) tier=zoomed cap=\(cap)"
                )
            }
        }
    }

    private func cancelZoomDecode() {
        zoomDecodeTask?.cancel()
        zoomDecodeTask = nil
    }

    @discardableResult
    private func installIfNotLowerQuality(
        _ candidate: UIKitViewerImageStore.DisplayImage,
        requestedCap: Int? = nil
    ) -> Bool {
        guard
            ViewerImageLoadPolicy.shouldReplaceDisplayedImage(
                currentLongestPixelSide: displayedLongestPixelSide,
                candidateLongestPixelSide: candidate.longestPixelSide
            )
        else {
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice(
                    """
                    [ViewerPerf] reject downgrade uid=\(MobileViewerLog.short(item.uid), privacy: .public) \
                    currentPx=\(displayedLongestPixelSide) candidatePx=\(candidate.longestPixelSide)
                    """
                )
            }
            return false
        }
        image = candidate.image
        displayedLongestPixelSide = max(displayedLongestPixelSide, candidate.longestPixelSide)
        if let requestedCap {
            displayedCap = max(displayedCap, requestedCap)
        }
        return true
    }
}

/// Native AVKit surface that keeps viewer gestures on UIKit's responder path. SwiftUI gestures attached outside
/// `VideoPlayer` do not reliably receive touches once AVKit's playback surface is active. AVKit documents its
/// content overlay for noninteractive decoration, so the recognizers live on the player controller's root view.
/// AVKit chrome is intentionally disabled because iOS exposes it only as one all-or-nothing surface; the app
/// owns the visible play and seek controls while AVKit retains playback, poster, and Picture in Picture behavior.
private struct MobileNativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let poster: UIImage?
    let reduceMotion: Bool
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize, CGFloat, Bool) -> Void
    let onPinchChanged: (CGFloat, UnitPoint) -> Void
    let onPinchEnded: (CGFloat, Bool) -> Void
    let onSingleTap: () -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.showsPlaybackControls = false
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.loadViewIfNeeded()
        context.coordinator.controller = controller
        context.coordinator.attachPoster(poster, to: controller)

        let gestureSurface = controller.view!

        let dismissPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDismissPan(_:))
        )
        dismissPan.maximumNumberOfTouches = 1
        dismissPan.cancelsTouchesInView = false
        dismissPan.delegate = context.coordinator
        gestureSurface.addGestureRecognizer(dismissPan)
        context.coordinator.dismissPan = dismissPan

        let dismissPinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDismissPinch(_:))
        )
        dismissPinch.cancelsTouchesInView = false
        dismissPinch.delegate = context.coordinator
        gestureSurface.addGestureRecognizer(dismissPinch)
        context.coordinator.dismissPinch = dismissPinch

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        singleTap.cancelsTouchesInView = false
        singleTap.delegate = context.coordinator
        gestureSurface.addGestureRecognizer(singleTap)
        context.coordinator.singleTap = singleTap

        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.controller = controller
        if controller.player !== player {
            controller.player = player
            context.coordinator.attachPoster(poster, to: controller)
        } else {
            context.coordinator.updatePoster(poster, in: controller)
        }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.teardownPoster()
        controller.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: MobileNativeVideoPlayer
        weak var controller: AVPlayerViewController?
        weak var dismissPan: UIPanGestureRecognizer?
        weak var dismissPinch: UIPinchGestureRecognizer?
        weak var singleTap: UITapGestureRecognizer?
        private weak var posterView: UIImageView?
        private var displayReadinessObservation: NSKeyValueObservation?

        init(parent: MobileNativeVideoPlayer) {
            self.parent = parent
        }

        func attachPoster(_ image: UIImage?, to controller: AVPlayerViewController) {
            teardownPoster()
            updatePoster(image, in: controller)
            displayReadinessObservation = controller.observe(
                \.isReadyForDisplay,
                options: [.initial, .new]
            ) { [weak self] _, change in
                guard change.newValue == true else { return }
                Task { @MainActor in self?.revealFirstFrame() }
            }
        }

        func updatePoster(_ image: UIImage?, in controller: AVPlayerViewController) {
            guard !controller.isReadyForDisplay, let image, let overlay = controller.contentOverlayView else {
                if image == nil { posterView?.removeFromSuperview() }
                return
            }
            let imageView: UIImageView
            if let posterView {
                imageView = posterView
            } else {
                imageView = UIImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.contentMode = .scaleAspectFit
                imageView.isUserInteractionEnabled = false
                overlay.addSubview(imageView)
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                    imageView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                    imageView.topAnchor.constraint(equalTo: overlay.topAnchor),
                    imageView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
                ])
                posterView = imageView
            }
            imageView.image = image
            imageView.alpha = 1
            imageView.isHidden = false
        }

        func teardownPoster() {
            displayReadinessObservation?.invalidate()
            displayReadinessObservation = nil
            posterView?.removeFromSuperview()
        }

        private func revealFirstFrame() {
            guard let posterView, !posterView.isHidden else { return }
            guard !parent.reduceMotion else {
                posterView.alpha = 0
                finishPosterReveal()
                return
            }
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                posterView.alpha = 0
            } completion: { _ in
                Task { @MainActor in self.finishPosterReveal() }
            }
        }

        private func finishPosterReveal() {
            posterView?.isHidden = true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === dismissPan || gestureRecognizer === dismissPinch, isNativeVideoZoomed {
                return false
            }
            guard gestureRecognizer === dismissPan,
                let pan = gestureRecognizer as? UIPanGestureRecognizer,
                let view = pan.view
            else { return true }
            let velocity = pan.velocity(in: view)
            // Match the photo page: only a vertical pan belongs to dismiss. Returning false here leaves a
            // horizontal drag to the enclosing UIPageViewController's existing previous/next interaction.
            return ViewerDragDismissPolicy.prefersDismissalAxis(
                velocity: CGSize(width: velocity.x, height: velocity.y))
        }

        /// AVKit owns video zoom and pan. Its public `videoBounds` reports the displayed media rect, so custom
        /// viewer-dismiss gestures must stand down once AVKit has enlarged it beyond the aspect-fit rect.
        private var isNativeVideoZoomed: Bool {
            guard let controller, let item = parent.player.currentItem else { return false }
            let presentationSize = item.presentationSize
            guard presentationSize.width > 0, presentationSize.height > 0,
                controller.view.bounds.width > 0, controller.view.bounds.height > 0
            else { return false }
            let fit = ViewerZoomGeometry.aspectFitRect(
                mediaSize: presentationSize,
                in: controller.view.bounds
            )
            return ViewerZoomGeometry.isZoomed(currentRect: controller.videoBounds, fitRect: fit)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let translation = gesture.translation(in: view)
            let value = CGSize(width: translation.x, height: translation.y)
            switch gesture.state {
            case .began, .changed:
                parent.onDragChanged(value)
            case .ended, .cancelled, .failed:
                parent.onDragEnded(value, gesture.velocity(in: view).y, gesture.state == .ended)
            default:
                break
            }
        }

        @objc func handleDismissPinch(_ gesture: UIPinchGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)
            let anchor = UnitPoint(
                x: view.bounds.width > 0 ? location.x / view.bounds.width : 0.5,
                y: view.bounds.height > 0 ? location.y / view.bounds.height : 0.5
            )
            switch gesture.state {
            case .began, .changed:
                parent.onPinchChanged(gesture.scale, anchor)
            case .ended, .cancelled, .failed:
                parent.onPinchEnded(gesture.scale, gesture.state == .ended)
            default:
                break
            }
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            parent.onSingleTap()
        }
    }
}

private struct MobileVideoPlaybackControls: View {
    let currentTime: Double
    let duration: Double
    let isPlaying: Bool
    let isLoading: Bool
    let onTogglePlayback: () -> Void
    let onSeekTo: (Double) -> Void

    @State private var scrubTime: Double?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var displayedTime: Double { scrubTime ?? currentTime }
    private var seekRange: ClosedRange<Double> { 0...max(duration, 0.1) }
    private var layoutProfile: ViewerChromeLayoutProfile {
        MobileViewerBottomLayout.profile(compactLandscape: verticalSizeClass == .compact)
    }

    var body: some View {
        VStack {
            Spacer()

            HStack(spacing: 12) {
                playbackButton(
                    symbol: isPlaying ? "pause.fill" : "play.fill",
                    labelKey: isPlaying ? "viewer.video_pause_a11y" : "viewer.video_play_a11y"
                ) {
                    onTogglePlayback()
                }
                Slider(
                    value: Binding(
                        get: { min(max(displayedTime, seekRange.lowerBound), seekRange.upperBound) },
                        set: { scrubTime = $0 }
                    ), in: seekRange
                ) { editing in
                    if !editing, let scrubTime {
                        onSeekTo(scrubTime)
                        self.scrubTime = nil
                    }
                }
                .accessibilityLabel(Text("viewer.video_position_a11y"))
                .accessibilityValue(Text(Self.positionDescription(displayedTime, duration: duration)))
                .tint(Color.primary)
                ProgressView()
                    .controlSize(.small)
                    .tint(.primary)
                    .frame(width: 24, height: layoutProfile.controlSide)
                    .opacity(isLoading ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityLabel(Text("viewer.video_loading_a11y"))
                    .accessibilityHidden(!isLoading)
            }
            .padding(.horizontal, 16)
            .frame(height: layoutProfile.controlSide)
            .glassEffect(in: Capsule())
            .padding(.horizontal, MobileViewerBottomLayout.horizontalPadding)
            // The filmstrip is safe-area content below the page, so the transport keeps only its row spacing.
            .padding(.bottom, layoutProfile.rowSpacing)
        }
    }

    private func playbackButton(
        symbol: String,
        labelKey: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(
                    width: layoutProfile.controlSide,
                    height: layoutProfile.controlSide
                )
        }
        .accessibilityLabel(Text(labelKey))
    }

    private static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let rounded = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", rounded / 60, rounded % 60)
    }

    private static func positionDescription(_ seconds: Double, duration: Double) -> String {
        "\(timestamp(seconds)) / \(timestamp(duration))"
    }
}

/// Native video playback via AVKit over the shared `VideoStreamProvider` streaming asset. The grid thumbnail
/// remains in AVKit's noninteractive content overlay until `isReadyForDisplay` proves the first video frame can
/// replace it. The app owns the visible playback controls because hiding AVKit's AirPlay and volume buttons also
/// hides its entire control surface. Paging and dismiss continue through the same shared policies as photos.
private struct MobileVideoPage: View {
    let item: PhotoItem
    let isCurrent: Bool
    let showsChrome: Bool
    let libraryModel: MobileLibraryModel
    let onToggleChrome: () -> Void
    let onCloseRequested: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player: AVPlayer?
    /// The streaming asset is the only strong owner of the range resource-loader, which AVFoundation holds
    /// weakly - it must live as long as the player, or every protonvideo:// range request goes unserved.
    @State private var streamingAsset: StreamingVideoAsset?
    @State private var failed = false
    @State private var poster: UIImage?
    @State private var pinch = ViewerPinchState()
    @State private var drag = ViewerDragState()
    @State private var viewportHeight: CGFloat = 0
    @State private var playbackTime: Double = 0
    @State private var playbackDuration: Double = 0
    @State private var playbackIsPlaying = false
    /// `timeControlStatus == .waitingToPlayAtSpecifiedRate` means playback still intends to continue after
    /// buffering. Keep that intent separate from the visible "currently progressing" state.
    @State private var playbackIntendsToPlay = false
    @State private var playbackIsBuffering = false
    @State private var playbackGeneration: UInt64 = 0
    @State private var playbackAttachment: VideoPlaybackAttachmentIdentity?
    @State private var playbackSourceIdentity: ObjectIdentifier?
    @State private var playbackSourceRevision: UInt64?
    @State private var playbackActivity: LibraryRuntimeActivityRegistration?
    @State private var holdsVideoAudio = false

    private var sourceIdentity: ObjectIdentifier? {
        guard let facade = libraryModel.facade else { return nil }
        return ObjectIdentifier(facade)
    }

    var body: some View {
        ZStack {
            if failed {
                ContentUnavailableView(
                    L10n.string("viewer.playback_failed"),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.white)
            } else if let player {
                MobileNativeVideoPlayer(
                    player: player,
                    poster: poster,
                    reduceMotion: reduceMotion,
                    onDragChanged: handleDragChanged,
                    onDragEnded: handleDragEnded,
                    onPinchChanged: handlePinchChanged,
                    onPinchEnded: handlePinchEnded,
                    onSingleTap: onToggleChrome
                )
                .ignoresSafeArea()
                .onAppear {
                    if isCurrent {
                        playbackIntendsToPlay = true
                        player.play()
                    }
                }

                if showsChrome {
                    MobileVideoPlaybackControls(
                        currentTime: playbackTime,
                        duration: playbackDuration,
                        isPlaying: playbackIsPlaying || playbackIsBuffering,
                        isLoading: MobileVideoPlaybackIntent.showsLoadingIndicator(
                            intendsToPlay: playbackIntendsToPlay,
                            isActivelyPlaying: playbackIsPlaying
                        ),
                        onTogglePlayback: togglePlayback,
                        onSeekTo: seek(to:)
                    )
                    .transition(.opacity)
                }
            } else {
                // AVKit is not mounted yet, so this is the only loading indicator. Once `player` is assigned,
                // the entire preparation layer leaves and can no longer cover native buffering or controls.
                if let poster {
                    Image(uiImage: poster)
                        .resizable()
                        .scaledToFit()
                        .allowsHitTesting(false)
                }
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .scaleEffect(pinch.displayScale * drag.scale, anchor: drag.isActive ? .center : pinch.anchor)
        .offset(drag.offset)
        // AVKit's surface carries the dismiss pan once the player is mounted. Before that, and when the video
        // cannot play, the same swipe down closes the viewer from anywhere on the page.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(placeholderDismissDrag, including: player == nil ? .all : .subviews)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            viewportHeight = $0
        }
        .task(
            id: LoadToken(
                uid: item.uid,
                current: isCurrent,
                sourceRevision: libraryModel.scopePresentationRevision,
                sourceIdentity: sourceIdentity
            )
        ) { await prepare() }
        .task(id: playbackAttachment?.generation) {
            guard let player, let generation = playbackAttachment?.generation else { return }
            await observePlayback(player, generation: generation)
        }
        .onChange(of: isCurrent) { _, current in
            if current {
                playbackIntendsToPlay = true
                player?.play()
            } else {
                playbackIntendsToPlay = false
                player?.pause()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) {
            [playbackGeneration] note in
            handleFailureNotification(note, generation: playbackGeneration)
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) {
            [playbackGeneration] note in
            handleEndNotification(note, generation: playbackGeneration)
        }
        .onAppear {
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice(
                    "[ViewerPerf] page appear uid=\(MobileViewerLog.short(item.uid), privacy: .public) current=\(isCurrent) kind=video"
                )
            }
        }
        .onDisappear {
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice(
                    "[ViewerPerf] page disappear uid=\(MobileViewerLog.short(item.uid), privacy: .public)")
            }
            teardown()
        }
    }

    private struct LoadToken: Equatable {
        let uid: PhotoUID
        let current: Bool
        let sourceRevision: UInt64
        let sourceIdentity: ObjectIdentifier?
    }

    @MainActor
    private func observePlayback(_ observedPlayer: AVPlayer, generation: UInt64) async {
        guard let observedItem = observedPlayer.currentItem else { return }
        var didReportDuration = false
        while !Task.isCancelled,
            isCurrentAttachment(generation: generation, player: observedPlayer, item: observedItem)
        {
            let time = observedPlayer.currentTime().seconds
            if time.isFinite { playbackTime = max(0, time) }
            let duration = observedItem.duration.seconds
            if duration.isFinite, duration > 0 { playbackDuration = duration }

            if !didReportDuration, duration.isFinite, duration > 0 {
                VideoPlaybackTuning.reportDuration(of: observedItem, to: streamingAsset)
                didReportDuration = true
            }

            if observedItem.status == .failed {
                failPlayback(
                    observedItem.error.map(VideoPlaybackError.classify)
                        ?? .playerItemFailed(detail: nil),
                    generation: generation,
                    player: observedPlayer,
                    item: observedItem
                )
                return
            }

            playbackIsPlaying = MobileVideoPlaybackIntent.isActivelyPlaying(observedPlayer.timeControlStatus)
            playbackIsBuffering = MobileVideoPlaybackIntent.isBuffering(observedPlayer.timeControlStatus)
            switch observedPlayer.timeControlStatus {
            case .playing, .waitingToPlayAtSpecifiedRate:
                playbackIntendsToPlay = true
            case .paused:
                playbackIntendsToPlay = false
            @unknown default:
                break
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        let willPlay = !playbackIntendsToPlay
        playbackIntendsToPlay = willPlay
        if willPlay {
            if MobileVideoPlaybackIntent.reachedEnd(current: playbackTime, duration: playbackDuration) {
                playbackTime = 0
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.play()
        } else {
            player.pause()
        }
        playbackIsPlaying = willPlay && player.timeControlStatus == .playing
        playbackIsBuffering = willPlay && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    private func seek(to seconds: Double) {
        guard let player else { return }
        let upper = playbackDuration > 0 ? playbackDuration : max(0, seconds)
        let target = min(max(0, seconds), upper)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playbackTime = target
    }

    private var placeholderDismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { handleDragChanged($0.translation) }
            .onEnded { handleDragEnded($0.translation, velocityY: $0.velocity.height, completed: true) }
    }

    private func handleDragChanged(_ translation: CGSize) {
        if !drag.isActive {
            guard ViewerDragDismissPolicy.engages(translation: translation, isZoomedIn: false) else { return }
            drag.isActive = true
        }
        let progress = ViewerDragDismissPolicy.progress(
            translationY: translation.height, viewportHeight: viewportHeight)
        drag.offset = translation
        drag.scale = ViewerDragDismissPolicy.displayScale(progress: progress)
    }

    private func handleDragEnded(_ translation: CGSize, velocityY: CGFloat, completed: Bool) {
        guard drag.isActive else { return }
        drag.isActive = false
        if completed,
            ViewerDragDismissPolicy.shouldDismiss(
                translationY: translation.height,
                velocityY: velocityY,
                viewportHeight: viewportHeight
            )
        {
            onCloseRequested()
        } else {
            withAnimation(
                MobileViewerMotionPolicy.animation(
                    .spring(
                        duration: ViewerDragDismissPolicy.springBackDuration,
                        bounce: 1 - Double(ViewerDragDismissPolicy.springBackDamping)
                    ),
                    reduceMotion: reduceMotion
                )
            ) {
                drag.offset = .zero
                drag.scale = 1
            }
        }
    }

    private func handlePinchChanged(_ gestureScale: CGFloat, anchor: UnitPoint) {
        if !pinch.isActive {
            guard ViewerPinchDismissPolicy.engages(gestureScale: gestureScale, isZoomedIn: false) else { return }
            pinch.isActive = true
            pinch.anchor = anchor
        }
        pinch.displayScale = ViewerPinchDismissPolicy.displayScale(gestureScale: gestureScale)
    }

    private func handlePinchEnded(_ gestureScale: CGFloat, completed: Bool) {
        guard pinch.isActive else { return }
        pinch.isActive = false
        if completed, ViewerPinchDismissPolicy.shouldDismiss(releaseScale: gestureScale) {
            onCloseRequested()
        } else {
            withAnimation(
                MobileViewerMotionPolicy.animation(
                    .spring(
                        duration: ViewerPinchDismissPolicy.springBackDuration,
                        bounce: 1 - Double(ViewerPinchDismissPolicy.springBackDamping)
                    ),
                    reduceMotion: reduceMotion
                )
            ) {
                pinch.displayScale = 1
            }
        }
    }

    private func prepare() async {
        // Reuse the grid thumbnail as the poster. Only the current page creates a player or network loader.
        if poster == nil {
            poster = libraryModel.thumbnailFeed?.memoryImage(for: item.uid)
        }
        let requestedSourceIdentity = sourceIdentity
        let requestedSourceRevision = libraryModel.scopePresentationRevision
        if player != nil,
            playbackSourceIdentity != requestedSourceIdentity
                || playbackSourceRevision != requestedSourceRevision
        {
            teardown()
        }
        guard isCurrent, player == nil, let backend = libraryModel.backend else { return }
        playbackGeneration &+= 1
        let generation = playbackGeneration
        failed = false
        let activity = LibraryRuntimeState.shared.beginActivity(.videoPlayback)
        defer {
            if playbackActivity !== activity { activity.end() }
        }
        if MobileViewerLog.isEnabled {
            MobileViewerLog.logger.notice(
                "[ViewerPerf] video prepare start uid=\(MobileViewerLog.short(item.uid), privacy: .public)")
        }
        do {
            let streaming =
                item.uid.isLocalPending
                ? try await libraryModel.viewerMedia.makeStreamingAsset(for: item.uid)
                : try await backend.makeStreamingAsset(for: item.uid)
            guard !Task.isCancelled, isCurrent,
                generation == playbackGeneration,
                requestedSourceIdentity == sourceIdentity,
                requestedSourceRevision == libraryModel.scopePresentationRevision
            else {
                streaming.close()
                return
            }
            let playerItem = AVPlayerItem(asset: streaming.asset)
            let newPlayer = AVPlayer(playerItem: playerItem)
            VideoPlaybackTuning.configure(player: newPlayer, item: playerItem, isStreaming: true)
            let attachment = VideoPlaybackAttachmentIdentity(
                generation: generation,
                player: newPlayer,
                item: playerItem
            )
            streamingAsset = streaming  // retain the resource loader for the player's lifetime
            playbackActivity = activity
            if !holdsVideoAudio {
                VideoAudioSession.begin()
                holdsVideoAudio = true
            }
            playbackAttachment = attachment
            playbackSourceIdentity = requestedSourceIdentity
            playbackSourceRevision = requestedSourceRevision
            player = newPlayer
            if isCurrent {
                playbackIntendsToPlay = true
                newPlayer.play()
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, isCurrent,
                generation == playbackGeneration,
                requestedSourceIdentity == sourceIdentity,
                requestedSourceRevision == libraryModel.scopePresentationRevision
            else { return }
            failed = true
        }
    }

    private func teardown() {
        playbackGeneration &+= 1
        playbackAttachment = nil
        playbackSourceIdentity = nil
        playbackSourceRevision = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        streamingAsset?.close()
        streamingAsset = nil
        playbackActivity?.end()
        playbackActivity = nil
        if holdsVideoAudio {
            VideoAudioSession.end()
            holdsVideoAudio = false
        }
        playbackTime = 0
        playbackDuration = 0
        playbackIsPlaying = false
        playbackIntendsToPlay = false
        playbackIsBuffering = false
    }

    private func isCurrentAttachment(
        generation: UInt64,
        player observedPlayer: AVPlayer,
        item observedItem: AVPlayerItem
    ) -> Bool {
        guard generation == playbackGeneration,
            let playbackAttachment,
            player === observedPlayer,
            observedPlayer.currentItem === observedItem
        else { return false }
        return playbackAttachment.matches(
            generation: generation,
            player: observedPlayer,
            item: observedItem
        )
    }

    private func handleFailureNotification(_ note: Notification, generation: UInt64) {
        guard let observedPlayer = player,
            let observedItem = note.object as? AVPlayerItem,
            isCurrentAttachment(generation: generation, player: observedPlayer, item: observedItem)
        else { return }
        let error =
            (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
            .map(VideoPlaybackError.classify)
            ?? .playerItemFailed(detail: "failedToPlayToEnd")
        failPlayback(error, generation: generation, player: observedPlayer, item: observedItem)
    }

    private func handleEndNotification(_ note: Notification, generation: UInt64) {
        guard let observedPlayer = player,
            let observedItem = note.object as? AVPlayerItem,
            isCurrentAttachment(generation: generation, player: observedPlayer, item: observedItem)
        else { return }
        playbackTime = max(playbackTime, playbackDuration)
        playbackIsPlaying = false
        playbackIntendsToPlay = false
        playbackIsBuffering = false
    }

    private func failPlayback(
        _: VideoPlaybackError,
        generation: UInt64,
        player observedPlayer: AVPlayer,
        item observedItem: AVPlayerItem
    ) {
        guard isCurrentAttachment(generation: generation, player: observedPlayer, item: observedItem) else { return }
        failed = true
        playbackGeneration &+= 1
        playbackAttachment = nil
        playbackSourceIdentity = nil
        playbackSourceRevision = nil
        observedPlayer.pause()
        observedPlayer.replaceCurrentItem(with: nil)
        player = nil
        streamingAsset?.close()
        streamingAsset = nil
        playbackActivity?.end()
        playbackActivity = nil
        if holdsVideoAudio {
            VideoAudioSession.end()
            holdsVideoAudio = false
        }
        playbackIsPlaying = false
        playbackIntendsToPlay = false
        playbackIsBuffering = false
    }
}

/// Live pinch-to-close state for the SwiftUI (video) page.
private struct ViewerPinchState {
    var isActive = false
    var displayScale: CGFloat = 1
    var anchor: UnitPoint = .center
}

/// Live one-finger drag-to-close state for the SwiftUI (video) page.
private struct ViewerDragState {
    var isActive = false
    var offset: CGSize = .zero
    var scale: CGFloat = 1
}

/// UIScrollView-backed zoomable image: pinch + double-tap to zoom, single-tap toggles chrome. At minimum zoom
/// the scroll view does not pan, so the enclosing page TabView keeps its swipe - and a pinch-IN at minimum
/// zoom hands the image to the shared pinch-to-close interaction (`ViewerPinchDismissPolicy`): it sticks to
/// the fingers, springs back below the threshold, closes past it.
private final class MobileViewerZoomScrollView: UIScrollView {
    var onViewportWillChange: (() -> Void)?
    var onLayout: (() -> Void)?

    override var frame: CGRect {
        willSet {
            if newValue.size != frame.size { onViewportWillChange?() }
        }
    }

    override var bounds: CGRect {
        willSet {
            if newValue.size != bounds.size { onViewportWillChange?() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

// Internal so the production UIKit adapter can keep its layout and zoom lifecycle behind the SwiftUI call site.
struct MobileZoomableImage: UIViewRepresentable {
    let image: UIImage
    let reduceMotion: Bool
    let onSingleTap: () -> Void
    let onCloseRequested: () -> Void
    /// Live Photo long-press: press-and-hold plays the paired motion clip, release stops it. Nil for a non-Live
    /// photo, in which case no long-press recognizer is installed.
    var onMotionStart: (() -> Void)? = nil
    var onMotionStop: (() -> Void)? = nil
    /// Reports the displayed photo rect (the aspect-fit image area, zoom- and pan-transformed) in the page's
    /// coordinate space whenever layout/zoom/pan changes it. Drives the photo-anchored Live badge and the
    /// motion overlay's geometry, so both stay glued to the photo instead of the viewer.
    var onPhotoFrameChanged: ((CGRect) -> Void)? = nil
    /// Fired when a zoom gesture or animation settles, with the final zoom scale. The page uses it to swap in a
    /// sharper decode sized for that zoom (never during the gesture, so the interaction stays fluid).
    var onZoomSettled: ((CGFloat) -> Void)? = nil
    /// On-device Live Text for the displayed still. `nil` removes text interaction from the photo.
    var liveTextAnalysis: ImageAnalysis? = nil
    /// Highlights the recognized text and makes it selectable. A Live Photo needs this, because its long press
    /// plays the motion; a still also selects text with a long press directly on the text.
    var liveTextHighlighted = false

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = MobileViewerZoomScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 4
        scrollView.minimumZoomScale = 1
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = .zero
        imageView.autoresizingMask = []
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView
        scrollView.onViewportWillChange = { [weak coordinator = context.coordinator] in
            coordinator?.captureVisibleAnchorBeforeViewportChange()
        }
        scrollView.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.updateZoomContentGeometry()
        }

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        // Pinch-to-close rides alongside the scroll view's own zoom pinch and takes over only when the
        // image is unzoomed and the fingers move inward (shared policy). It never blocks zooming.
        let dismissPinch = UIPinchGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleDismissPinch(_:)))
        dismissPinch.delegate = context.coordinator
        scrollView.addGestureRecognizer(dismissPinch)

        // One-finger drag-to-close begins only on a clearly vertical drag while unzoomed (shared policy +
        // `gestureRecognizerShouldBegin`), so a horizontal drag falls through to the page TabView's swipe and a
        // zoomed image still pans normally. It tracks the finger and closes / springs back on release.
        let dismissPan = UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleDismissPan(_:)))
        dismissPan.delegate = context.coordinator
        dismissPan.maximumNumberOfTouches = 1
        scrollView.addGestureRecognizer(dismissPan)
        context.coordinator.dismissPan = dismissPan

        // Live Photo long-press: a stationary press-and-hold plays the paired motion clip; release/cancel stops
        // it. Installed only for Live Photos (callbacks non-nil). Rides alongside the other recognizers, so any
        // drag cancels it back to the still and pans/zooms as usual.
        if onMotionStart != nil {
            let longPress = UILongPressGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
            longPress.minimumPressDuration = 0.3
            longPress.delegate = context.coordinator
            scrollView.addGestureRecognizer(longPress)
            context.coordinator.motionPress = longPress
        }

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onCloseRequested = onCloseRequested
        context.coordinator.onMotionStart = onMotionStart
        context.coordinator.onMotionStop = onMotionStop
        context.coordinator.onPhotoFrameChanged = onPhotoFrameChanged
        context.coordinator.onZoomSettled = onZoomSettled
        context.coordinator.reduceMotion = reduceMotion
        context.coordinator.updateLiveText(analysis: liveTextAnalysis, highlighted: liveTextHighlighted)
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            // Geometry must be current before SwiftUI presents the replacement image. Reporting the new
            // frame stays deferred because the callback writes page @State during this representable update.
            context.coordinator.updateZoomContentGeometry(reportChanges: false)
        }
        // Initial/refresh report, async: we're inside a SwiftUI view update, and the callback writes @State.
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            coordinator?.reportPhotoFrame()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSingleTap: onSingleTap,
            onCloseRequested: onCloseRequested,
            onMotionStart: onMotionStart,
            onMotionStop: onMotionStop,
            reduceMotion: reduceMotion
        )
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate,
        ImageAnalysisInteractionDelegate
    {
        var imageView: UIImageView?
        weak var scrollView: UIScrollView?
        var onSingleTap: () -> Void
        var onCloseRequested: () -> Void
        var onMotionStart: (() -> Void)?
        var onMotionStop: (() -> Void)?
        var onPhotoFrameChanged: ((CGRect) -> Void)?
        var onZoomSettled: ((CGFloat) -> Void)?
        var reduceMotion: Bool
        /// Last reported photo rect - reports are de-duplicated so a steady frame never spams @State updates.
        private var lastReportedPhotoFrame: CGRect = .null

        private var dismissPinchActive = false
        private var pinchStartCentroid: CGPoint = .zero
        weak var dismissPan: UIPanGestureRecognizer?
        weak var motionPress: UILongPressGestureRecognizer?
        private var liveTextInteraction: ImageAnalysisInteraction?
        private var dismissPanActive = false
        private var motionActive = false
        private var updatingZoomGeometry = false
        private var lastZoomViewport: CGSize = .zero
        private var lastZoomMediaSize: CGSize = .zero
        private var pendingVisibleAnchor: CGPoint?

        init(
            onSingleTap: @escaping () -> Void,
            onCloseRequested: @escaping () -> Void,
            onMotionStart: (() -> Void)?,
            onMotionStop: (() -> Void)?,
            reduceMotion: Bool
        ) {
            self.onSingleTap = onSingleTap
            self.onCloseRequested = onCloseRequested
            self.onMotionStart = onMotionStart
            self.onMotionStop = onMotionStop
            self.reduceMotion = reduceMotion
        }

        /// Live Photo playback: begin on the long-press threshold, end on release/cancel. The `motionActive`
        /// guard means a stray terminal state without a matching `.began` can never fire a spurious stop.
        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                motionActive = true
                onMotionStart?()
            case .ended, .cancelled, .failed:
                if motionActive {
                    motionActive = false
                    onMotionStop?()
                }
            default:
                break
            }
        }

        /// Keeps UIKit's zoom document equal to the actual fitted media, rather than the whole viewport.
        /// This leaves native rubber-band behavior intact while making its settled edges the photo edges.
        func captureVisibleAnchorBeforeViewportChange() {
            guard !updatingZoomGeometry, pendingVisibleAnchor == nil,
                let scrollView, lastZoomViewport != .zero,
                scrollView.zoomScale > scrollView.minimumZoomScale + 0.01,
                scrollView.contentSize != .zero
            else { return }
            let settledOrigin = ViewerZoomGeometry.settledOrigin(
                proposedOrigin: scrollView.contentOffset,
                contentSize: scrollView.contentSize,
                viewportSize: lastZoomViewport
            )
            pendingVisibleAnchor = ViewerZoomGeometry.normalizedVisibleAnchor(
                contentOrigin: settledOrigin,
                contentSize: scrollView.contentSize,
                viewportSize: lastZoomViewport
            )
        }

        func updateZoomContentGeometry(reportChanges: Bool = true) {
            guard !updatingZoomGeometry, let scrollView, let imageView, let image = imageView.image else { return }
            let viewport = scrollView.bounds.size
            guard viewport.width > 0, viewport.height > 0 else { return }
            if viewport == lastZoomViewport, image.size == lastZoomMediaSize {
                if reportChanges { reportPhotoFrame() }
                return
            }
            let fitSize = ViewerZoomGeometry.aspectFitSize(mediaSize: image.size, viewportSize: viewport)
            guard fitSize != .zero else { return }

            updatingZoomGeometry = true
            let zoom = max(scrollView.minimumZoomScale, scrollView.zoomScale)
            let oldContentSize = scrollView.contentSize
            let oldOffset = scrollView.contentOffset
            let oldViewport = lastZoomViewport == .zero ? viewport : lastZoomViewport
            let settledOldOrigin = ViewerZoomGeometry.settledOrigin(
                proposedOrigin: oldOffset,
                contentSize: oldContentSize,
                viewportSize: oldViewport
            )
            let visibleAnchor =
                pendingVisibleAnchor
                ?? ViewerZoomGeometry.normalizedVisibleAnchor(
                    contentOrigin: settledOldOrigin,
                    contentSize: oldContentSize,
                    viewportSize: oldViewport
                )
            pendingVisibleAnchor = nil
            // Reset the native zoom transform before changing bounds and center. Restoring it below makes
            // UIScrollView recompute its scaled content size for the new fitted media geometry.
            if zoom > scrollView.minimumZoomScale + 0.001 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
            }
            // UIKit applies the zoom as a transform. `bounds` and `center` remain valid while transformed;
            // changing `frame` during rotation or a sharp-image upgrade is undefined.
            imageView.bounds = CGRect(origin: .zero, size: fitSize)
            imageView.center = CGPoint(x: fitSize.width / 2, y: fitSize.height / 2)
            scrollView.contentSize = fitSize
            scrollView.contentInset = .zero
            // iOS 26 is the package minimum. Center the smaller axis without adding pannable letterbox.
            scrollView.contentAlignmentPoint = CGPoint(x: 0.5, y: 0.5)
            if abs(zoom - scrollView.zoomScale) > 0.001 {
                scrollView.setZoomScale(zoom, animated: false)
            }
            if zoom > scrollView.minimumZoomScale + 0.01, oldContentSize != .zero {
                let scaledContentSize = scrollView.contentSize
                let settled = ViewerZoomGeometry.rebasedOrigin(
                    anchor: visibleAnchor,
                    contentSize: scaledContentSize,
                    viewportSize: viewport
                )
                scrollView.contentOffset = settled
            }
            lastZoomViewport = viewport
            lastZoomMediaSize = image.size
            updatingZoomGeometry = false
            liveTextInteraction?.setContentsRectNeedsUpdate()
            if reportChanges { reportPhotoFrame() }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        /// The displayed photo rect: the aspect-FIT area of the image inside the (zoom-scaled) image view,
        /// converted to the scroll view's superview space - the same space the page's SwiftUI overlays use.
        func displayedPhotoFrame() -> CGRect? {
            guard let scrollView, let imageView, let img = imageView.image,
                img.size.width > 0, img.size.height > 0
            else { return nil }
            return imageView.convert(imageView.bounds, to: scrollView.superview)
        }

        func reportPhotoFrame() {
            guard let frame = displayedPhotoFrame() else { return }
            // Sub-point changes are invisible; skip them so pan/zoom doesn't flood SwiftUI with state writes.
            if abs(frame.minX - lastReportedPhotoFrame.minX) < 0.5,
                abs(frame.minY - lastReportedPhotoFrame.minY) < 0.5,
                abs(frame.width - lastReportedPhotoFrame.width) < 0.5,
                abs(frame.height - lastReportedPhotoFrame.height) < 0.5
            {
                return
            }
            lastReportedPhotoFrame = frame
            onPhotoFrameChanged?(frame)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            if !updatingZoomGeometry { reportPhotoFrame() }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if !updatingZoomGeometry { reportPhotoFrame() }
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            reportPhotoFrame()
            onZoomSettled?(scale)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        /// Gate the dismiss pan so it begins only on a clearly vertical drag while the image is unzoomed - a
        /// horizontal drag then falls through to the page TabView's paging swipe, and a zoomed image keeps its
        /// scroll-view pan. Every other recognizer begins normally.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // A press on recognized text selects it, as in Photos; a press anywhere else plays the Live Photo.
            if gestureRecognizer === motionPress {
                return !liveTextOwns(gestureRecognizer) && !isOnText(gestureRecognizer)
            }
            guard gestureRecognizer === dismissPan, let scrollView else { return true }
            let isZoomedIn = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            guard !isZoomedIn else { return false }
            let v = (gestureRecognizer as? UIPanGestureRecognizer)?.velocity(in: scrollView) ?? .zero
            return ViewerDragDismissPolicy.prefersDismissalAxis(
                velocity: CGSize(width: v.x, height: v.y))
        }

        @objc func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView, let container = scrollView.superview else { return }
            let translation = gesture.translation(in: container)
            switch gesture.state {
            case .began, .changed:
                if !dismissPanActive {
                    let isZoomedIn = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
                    guard
                        ViewerDragDismissPolicy.engages(
                            translation: CGSize(width: translation.x, height: translation.y), isZoomedIn: isZoomedIn)
                    else { return }
                    dismissPanActive = true
                }
                let progress = ViewerDragDismissPolicy.progress(
                    translationY: translation.y, viewportHeight: container.bounds.height)
                let scale = ViewerDragDismissPolicy.displayScale(progress: progress)
                scrollView.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
                    .scaledBy(x: scale, y: scale)
            case .ended, .cancelled, .failed:
                guard dismissPanActive else { return }
                dismissPanActive = false
                let velocity = gesture.velocity(in: container)
                if gesture.state == .ended,
                    ViewerDragDismissPolicy.shouldDismiss(
                        translationY: translation.y, velocityY: velocity.y, viewportHeight: container.bounds.height)
                {
                    onCloseRequested()
                } else {
                    guard !reduceMotion else {
                        scrollView.transform = .identity
                        return
                    }
                    UIView.animate(
                        withDuration: ViewerDragDismissPolicy.springBackDuration,
                        delay: 0,
                        usingSpringWithDamping: ViewerDragDismissPolicy.springBackDamping,
                        initialSpringVelocity: 0,
                        options: [.allowUserInteraction, .beginFromCurrentState]
                    ) {
                        scrollView.transform = .identity
                    }
                }
            default:
                break
            }
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            // A tap that clears a text selection or opens a highlighted item belongs to Live Text, not to the chrome.
            if let interaction = liveTextInteraction, interaction.hasActiveTextSelection || liveTextOwns(gesture) {
                return
            }
            onSingleTap()
        }

        // MARK: Live Text

        func updateLiveText(analysis: ImageAnalysis?, highlighted: Bool) {
            guard let imageView else { return }
            guard let analysis else {
                liveTextInteraction?.selectableItemsHighlighted = false
                liveTextInteraction?.analysis = nil
                imageView.isUserInteractionEnabled = false
                return
            }
            let interaction: ImageAnalysisInteraction
            if let existing = liveTextInteraction {
                interaction = existing
            } else {
                interaction = ImageAnalysisInteraction(self)
                interaction.preferredInteractionTypes = .automaticTextOnly
                // The viewer toolbar owns the Show Text action; the system button would scale with the zoom.
                interaction.isSupplementaryInterfaceHidden = true
                imageView.addInteraction(interaction)
                liveTextInteraction = interaction
            }
            if interaction.analysis !== analysis { interaction.analysis = analysis }
            if interaction.selectableItemsHighlighted != highlighted {
                interaction.selectableItemsHighlighted = highlighted
            }
            imageView.isUserInteractionEnabled = true
        }

        /// True when `gesture` is on highlighted text, a highlighted code, or another highlighted item.
        private func liveTextOwns(_ gesture: UIGestureRecognizer) -> Bool {
            guard let interaction = liveTextInteraction, let imageView, interaction.analysis != nil,
                interaction.selectableItemsHighlighted
            else { return false }
            return interaction.hasInteractiveItem(at: gesture.location(in: imageView))
        }

        /// True when `gesture` starts on recognized text, highlighted or not. The analysis knows every text
        /// region up front, so a Live Photo's press on text can leave the selection to Live Text.
        private func isOnText(_ gesture: UIGestureRecognizer) -> Bool {
            guard let interaction = liveTextInteraction, let imageView, interaction.analysis != nil else {
                return false
            }
            return interaction.analysisHasText(at: gesture.location(in: imageView))
        }

        func interaction(
            _ interaction: ImageAnalysisInteraction,
            shouldBeginAt point: CGPoint,
            for interactionType: ImageAnalysisInteraction.InteractionTypes
        ) -> Bool {
            if interaction.selectableItemsHighlighted { return true }
            // Unhighlighted, only a press on text starts a selection, on stills and Live Photos alike. Taps and
            // double taps keep their viewer meaning, and a press beside the text plays the Live Photo.
            guard interactionType.contains(.textSelection) else { return false }
            return interaction.analysisHasText(at: point)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: !reduceMotion)
            } else {
                let point = gesture.location(in: imageView)
                let side = scrollView.bounds.size
                let zoomRect = CGRect(
                    x: point.x - side.width / 6, y: point.y - side.height / 6,
                    width: side.width / 3, height: side.height / 3)
                scrollView.zoom(to: zoomRect, animated: !reduceMotion)
            }
            // Programmatic zooms don't reliably deliver `scrollViewDidEndZooming` - settle explicitly once the
            // zoom animation is over, so a double-tap zoom also gets its sharper decode.
            DispatchQueue.main.asyncAfter(
                deadline: .now() + MobileViewerMotionPolicy.duration(0.4, reduceMotion: reduceMotion)
            ) { [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                self.reportPhotoFrame()
                self.onZoomSettled?(scrollView.zoomScale)
            }
        }

        @objc func handleDismissPinch(_ gesture: UIPinchGestureRecognizer) {
            guard let scrollView, let container = scrollView.superview else { return }
            switch gesture.state {
            case .began, .changed:
                if !dismissPinchActive {
                    let isZoomedIn = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
                    guard ViewerPinchDismissPolicy.engages(gestureScale: gesture.scale, isZoomedIn: isZoomedIn)
                    else { return }
                    dismissPinchActive = true
                    pinchStartCentroid = gesture.location(in: container)
                    // Take the gesture over from the scroll view's bounce-zoom for its remainder.
                    scrollView.pinchGestureRecognizer?.isEnabled = false
                    scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
                }
                let scale = ViewerPinchDismissPolicy.displayScale(gestureScale: gesture.scale)
                let centroid = gesture.location(in: container)
                let center = scrollView.center
                // Keep the image point that was under the fingers under the fingers: scale about the view
                // center, then translate so the engaged centroid tracks the live centroid.
                let tx = centroid.x - center.x - scale * (pinchStartCentroid.x - center.x)
                let ty = centroid.y - center.y - scale * (pinchStartCentroid.y - center.y)
                scrollView.transform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
            case .ended, .cancelled, .failed:
                guard dismissPinchActive else { return }
                dismissPinchActive = false
                scrollView.pinchGestureRecognizer?.isEnabled = true
                if gesture.state == .ended, ViewerPinchDismissPolicy.shouldDismiss(releaseScale: gesture.scale) {
                    onCloseRequested()
                } else {
                    guard !reduceMotion else {
                        scrollView.transform = .identity
                        return
                    }
                    UIView.animate(
                        withDuration: ViewerPinchDismissPolicy.springBackDuration,
                        delay: 0,
                        usingSpringWithDamping: ViewerPinchDismissPolicy.springBackDamping,
                        initialSpringVelocity: 0,
                        options: [.allowUserInteraction, .beginFromCurrentState]
                    ) {
                        scrollView.transform = .identity
                    }
                }
            default:
                break
            }
        }
    }
}

/// Hosts the Live Photo motion clip's `AVPlayerLayer` over the still - aspect-fit, transparent, non-interactive
/// (the still underneath keeps the zoom/tap gestures). Mirrors the macOS `MotionPlayerLayerView`.
private struct MobileMotionPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .clear
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// A small status badge on the media: "LIVE" signals the press-and-hold-to-play interaction of a Live Photo,
/// "ORIGINAL" marks the shown original of an edited photo.
private struct MobileViewerBadge: View {
    let title: String
    let systemImage: String
    let accessibilityLabel: String

    static var live: MobileViewerBadge {
        MobileViewerBadge(
            title: L10n.string("viewer.live_badge"), systemImage: "livephoto",
            accessibilityLabel: L10n.string("viewer.live_photo_a11y"))
    }
    static var original: MobileViewerBadge {
        MobileViewerBadge(
            title: L10n.string("viewer.original_badge"), systemImage: "wand.and.rays.inverse",
            accessibilityLabel: L10n.string("viewer.original_badge_a11y"))
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}
